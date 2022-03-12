#!/bin/env bash

NETWORK=$1
ACTION=$2
FLAG=$3
FLAG2=$4
PARAM=""
PROFILE="stacks-blockchain"
EVENT_REPLAY=""
FLAGS=""
export SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
ENV_FILE="${SCRIPTPATH}/.env"
source ${ENV_FILE}

exit_error() {
   printf "%s\n" "$1" >&2
   exit 1
}

for cmd in docker-compose docker; do
   command -v $cmd >/dev/null 2>&1 || exit_error "Missing command: $cmd"
done

set -eo pipefail
set -Eo functrace

log() {
   printf >&2 "%s\n" "$1"
}

usage() {
	log "Usage:"
	log "  $0 <network> <action> <optional flags>"
	log "      network: [ mainnet | testnet | mocknet | bns ]"
	log "      action: [ up | down | logs | reset | upgrade | import | export ]"
	log "      optional flags: [ proxy | bitcoin ]"
	log "      example: $0 mainnet up"
	exit_error ""
}

confirm() {
  while true; do
    read -r -n 1 -p "${1:-Continue?} [y/n]: " REPLY
    case $REPLY in
      [yY]) echo ; return 0 ;;
      [nN]) echo ; return 1 ;;
      *) printf " \033[31m %s \n\033[0m" "invalid input"
    esac 
  done
}

check_network() {
	if [[ $(docker-compose -f ${SCRIPTPATH}/configurations/common.yaml ps -q) ]]; then
		# docker running
		return 0
	fi
	# docker is not running
	return 1
}

status(){
	if check_network; then
		log "Stacks Blockchain services are running"
		docker-compose -f ${SCRIPTPATH}/configurations/common.yaml ps
	else
		exit_error "Stacks Blockchain services are not running"
	fi
}

check_device() {
    if [[ `uname -m` == 'arm64' ]]; then
		echo
        log "⚠️  WARNING"
        log "⚠️  MacOS M1 CPU detected - NOT recommended for this repo"
        log "⚠️  see README for details"
        log "⚠️  https://github.com/stacks-network/stacks-blockchain-docker#macos-with-an-m1-processor-is-not-recommended-for-this-repo"
        # read -p "Press enter to continue anyway or Ctrl+C to exit"
		confirm "Continue Anyway?" || exit_error "Exiting"
    fi
}

check_api_breaking_change(){
	CURRENT_API_VERSION=$(docker images --format "{{.Tag}}" blockstack/stacks-blockchain-api  | cut -f 1 -d "." | head -1)
	CONFIGURED_API_VERSION=$( echo $STACKS_BLOCKCHAIN_API_VERSION | cut -f 1 -d ".")
	if [ "$CURRENT_API_VERSION" != "" ]; then
		if [ $CURRENT_API_VERSION -lt $CONFIGURED_API_VERSION ];then
			echo
			log "*** stacks-blockchain-api contains a breaking schema change ( Version: ${STACKS_BLOCKCHAIN_API_VERSION} ) ***"
			return 1
		fi
	fi
	log "return 0"
	return 0
}

event_replay(){
	EVENT_REPLAY="-f ${SCRIPTPATH}/configurations/api-import-events.yaml"
	PROFILE="event-replay"
	docker_up
	echo
	log "*** This operation can take a long while ***"
	log "    check logs for completion: $0 $NETWORK logs "
	log "  Once the operation is complete, restart the service with: $0 $NETWORK restart"
	echo
	exit 0
}

download_bns_data() {
	if [ "$BNS_IMPORT_DIR" != "" ]; then
		if ! check_network; then
			echo
			log "Downloading and extracting V1 bns-data"
			log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bns.yaml up"
			docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bns.yaml --profile bns up
			log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bns.yaml down"
			docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bns.yaml --profile bns down
			echo
			log "Download Operation is complete, start the service with: $0 mainnet up"
			echo
			exit 0
		else
			echo
			log "Can't download BNS data while services are running"
			status
			exit_error ""
		fi
	else
		echo
		exit_error "Undefined or commented BNS_IMPORT_DIR variable in $ENV_FILE"
	fi
}

run_bitcoin_node() {
	log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml up"
	docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml up -d
	log "Running bitcoin node. Performing sync..."
	log "Process will wait to fully sync the bitcoin node before it continues. Please be patient. First sync could take several hours or even days to complete."
	log "Bitcoin blockchain is quite large (around 500GB and growing), so you can optionaly choose where this data is stored in the .env file, by changing the variable BITCOIN_BLOCKCHAIN_FOLDER which is currently set to ${BITCOIN_BLOCKCHAIN_FOLDER}".
	docker logs -f bitcoin-core 2>&1 | grep -m 1 " progress=1.000000 cache="
	log "Bitcoin node sync complete. Bitcoin node is fully operational."
}

reset_data() {
	if [ -d ${SCRIPTPATH}/persistent-data/${NETWORK} ]; then
		if ! check_network; then
			log "Resetting Persistent data for ${NETWORK}"
			log "Running: rm -rf ${SCRIPTPATH}/persistent-data/${NETWORK}"
			rm -rf ${SCRIPTPATH}/persistent-data/${NETWORK}
		else
			log "Can't reset while services are running"
			exit_error "    Run: $0 ${NETWORK} down and try again"
		fi
	fi
	exit 0
}

ordered_stop() {
	log "Stopping stacks-blockchain first to prevent database errors"
	log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/common.yaml -f ${SCRIPTPATH}/configurations/${NETWORK}.yaml --profile ${PROFILE} stop stacks-blockchain"
	              docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/common.yaml -f ${SCRIPTPATH}/configurations/${NETWORK}.yaml --profile ${PROFILE} stop stacks-blockchain
	# Check if bitcoin blockchain is also running. If it is, stop it.
	if [[ $(docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml ps -q bitcoin-core) ]]; then
		log "Bitcoin blockchain is currently running. Stopping..."
		# "Not Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml --profile ${PROFILE} down" because it would also remove the Stacks network
		# Instead I need to first stop and then remove only the container (so the network stays on)
		log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml --profile ${PROFILE} stop bitcoin-core"
		              docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml --profile ${PROFILE} stop bitcoin-core
		log "Running: docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml --profile ${PROFILE} rm -f bitcoin-core"
			          docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/bitcoin.yaml --profile ${PROFILE} rm -f bitcoin-core
	fi
}

docker_logs(){
	PARAM="-f"
	if ! check_network; then
		log "*** No ${NETWORK} services running ***"
		usage
	fi
	run_docker
}

docker_down () {
	ACTION="down"
	if ! check_network; then
		log "*** stacks-blockchain network is not running ***"
		return
	fi
	if [[ ${NETWORK} == "mainnet" || ${NETWORK} == "testnet" ]];then
		ordered_stop
	fi
	run_docker
}

docker_up() {
	if ! check_api_breaking_change; then
		log "    Required to perform a stacks-blockchain-api event-replay:"
		log "        https://github.com/hirosystems/stacks-blockchain-api#event-replay "
		log "    Or downgrade the API version in ${ENV_FILE}: STACKS_BLOCKCHAIN_API_VERSION=$(docker images --format "{{.Tag}}" blockstack/stacks-blockchain-api  | head -1)"
		if confirm "Run event-replay now?"; then
			log "*** RUNNING EVENT REPLAY ***"
			if check_network; then
				docker_down
			fi
			ACTION="pull"
			run_docker
			EVENT_REPLAY="-f ${SCRIPTPATH}/configurations/api-import-events.yaml"
			event_replay
		fi
		exit_error "Exiting - event replay is required"
	fi
	ACTION="up"
	if check_network; then
		exit_error "*** stacks-blockchain network is already running ***"
	fi
	if [[ ${NETWORK} == "mainnet" ||  ${NETWORK} == "testnet" ]];then
		if [[ ! -d ${SCRIPTPATH}/persistent-data/${NETWORK} ]];then
			log "Creating persistent-data for ${NETWORK}"
			mkdir -p ${SCRIPTPATH}/persistent-data/${NETWORK}/event-replay
		fi
	fi

	#Create Config.toml from sample if it doesn't exist.
	#If bitcoin flag is on when using mainet or testnet then use the Config.toml in `${NETWORK}-btc` instead, so the stacks node uses the local bitcoin node instead of the remote one. 
	case ${FLAG}${FLAG2} in
			*bitcoin*)
				# BITCOIN FLAG IN ON
				if [[ ${NETWORK} == "mainnet" ||  ${NETWORK} == "testnet"  ]]; then 
					[[ ! -f "${SCRIPTPATH}/configurations/${NETWORK}-btc/Config.toml" ]] && cp ${SCRIPTPATH}/configurations/${NETWORK}-btc/Config.toml.sample ${SCRIPTPATH}/configurations/${NETWORK}-btc/Config.toml
				fi			
				;;
			*) # BITCOIN FLAG IS NOT ON
				[[ ! -f "${SCRIPTPATH}/configurations/${NETWORK}/Config.toml" ]] && cp ${SCRIPTPATH}/configurations/${NETWORK}/Config.toml.sample ${SCRIPTPATH}/configurations/${NETWORK}/Config.toml
				;;
	esac
	
	if [[ ${NETWORK} == "private-testnet" ]]; then
		[[ ! -f "${SCRIPTPATH}/configurations/${NETWORK}/puppet-chain.toml" ]] && cp ${SCRIPTPATH}/configurations/${NETWORK}/puppet-chain.toml.sample ${SCRIPTPATH}/configurations/${NETWORK}/puppet-chain.toml
		[[ ! -f "${SCRIPTPATH}/configurations/${NETWORK}/bitcoin.conf" ]] && cp ${SCRIPTPATH}/configurations/${NETWORK}/bitcoin.conf.sample ${SCRIPTPATH}/configurations/${NETWORK}/bitcoin.conf
	fi
	PARAM="-d"
	run_docker
}

run_docker() {
	# case will run if word bitcoin in contained in flag1 or flag2
	# If bitcoin flag is detected, I should run bitcoin node before anything else
	case ${FLAG}${FLAG2} in
		*bitcoin*)
			# "BITCOIN FLAG IN ON!"
			if [[ ${NETWORK} == "mainnet" ||  ${NETWORK} == "testnet"  ]]; then 
				run_bitcoin_node
				echo "Running docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/common.yaml -f ${SCRIPTPATH}/configurations/${NETWORK}-btc.yaml ${EVENT_REPLAY} ${FLAGS} --profile ${PROFILE} ${ACTION} ${PARAM}"
				docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/common.yaml -f ${SCRIPTPATH}/configurations/${NETWORK}-btc.yaml ${EVENT_REPLAY} ${FLAGS} --profile ${PROFILE} ${ACTION} ${PARAM}
			else
				log "UNSUPPORTED OPTION: You can only run the bitcoin node on mainnet or testnet, not on ${NETWORK}."
				usage
			fi			
			;;
		*)
			docker-compose --env-file ${ENV_FILE} -f ${SCRIPTPATH}/configurations/common.yaml -f ${SCRIPTPATH}/configurations/${NETWORK}.yaml ${EVENT_REPLAY} ${FLAGS} --profile ${PROFILE} ${ACTION} ${PARAM}
			;;
	esac
	if [[ $? -eq 0 && ${ACTION} == "up" ]]; then
		log "Brought up ${NETWORK}, use '$0 ${NETWORK} logs' to follow log files."
	fi
}

case ${ACTION} in
	# ensure we also act on any proxy containers based on ACTION
    down|stop|logs|upgrade|pull|export|import)
        FLAGS="${FLAGS}-f ${SCRIPTPATH}/configurations/proxy.yaml" 
        ;;
    *)
		# set the FLAG regardless of ACTION if defined
		# case will run if word proxy or nginx is contained in flag1 or flag2
        case ${FLAG}${FLAG2} in
            *proxy*|*nginx*)
                FLAGS="${FLAGS}-f ${SCRIPTPATH}/configurations/proxy.yaml"
                ;;
        esac
        ;;
esac 


case ${NETWORK} in
	mainnet|testnet|mocknet|private-testnet)
		;;
	bns)
		download_bns_data
		;;
  	*)
		usage
    	;;
esac


case ${ACTION} in

	up|start)
		check_device
		docker_up
		;;
	down|stop)
		docker_down
		;;
	restart)
		docker_down
		docker_up
		;;
	logs)
		docker_logs
		;;
	import)
		if check_network; then
			docker_down
		fi
		EVENT_REPLAY="-f ${SCRIPTPATH}/configurations/api-import-events.yaml"
		event_replay
		;;
	export)
		if check_network; then
			docker_down
		fi
		EVENT_REPLAY="-f ${SCRIPTPATH}/configurations/api-export-events.yaml"
		event_replay
		;;
	upgrade|pull)
		ACTION="pull"
		run_docker
		;;
	status)
		status
		;;
	reset)
		reset_data
		run_docker
		;;
	*)
		usage
		;;
esac
exit 0
