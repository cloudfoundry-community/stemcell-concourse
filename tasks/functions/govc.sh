#!/bin/bash

#
# Task Description:
#   Functions to interact with govc cli

######################################
# Description: Initialize GOVC_* environment variables used by the govc binary.
# Globals:
#	GOVC_EXE
#	GOVC_URL
#	GOVC_USERNAME
#	GOVC_PASSWORD
#	GOVC_INSECURE
#	GOVC_TLS_CA_CERTS
# Arguments:
#	vcenter_host
#	vcenter_username
#	vcenter_password
#	vcenter_ca_cert
#	govc_file_path
# Returns:
#	None
#######################################
function initializeGovc() {
	local vcenter_host="${1}"
	local vcenter_username="${2}"
	local vcenter_password="${3}"
	local vcenter_ca_cert="${4}"
	local vcenter_datacenter="${5}"

	echo "Initializing govc"

	export GOVC_EXE="govc"
	export GOVC_URL="${vcenter_host}"
	export GOVC_USERNAME="${vcenter_username}"
	export GOVC_PASSWORD="${vcenter_password}"
	export GOVC_DATACENTER="${vcenter_datacenter}"
	export GOVC_INSECURE=0
	
	if [[ -z "${vcenter_ca_cert}" ]]; then
		echo "  Downloading vCenter certificate"
		#export GOVC_INSECURE=1
		if ! certPath=$(downloadVCCertificate "${vcenter_host}" 2>&1); then
			echo "${certPath}"
			writeErr "Tried to download vCenter certificate but failed"
			return 1
		fi

		GOVC_TLS_CA_CERTS="$(pwd)/${certPath}"
		export GOVC_TLS_CA_CERTS
	else
		echo "  Using provided certificate"
		GOVC_TLS_CA_CERTS=$(mktemp)
		export GOVC_TLS_CA_CERTS
		cat <<< "${vcenter_ca_cert}" > "${GOVC_TLS_CA_CERTS}"
	fi

	if [ -z "${GOVC_EXE}" ]; then
		writeErr "govc binary not found"
		return 1;
	fi

	if ! command -v "${GOVC_EXE}" >/dev/null; then
		writeErr "govc binary invalid"
		return 1;
	fi

	# test that we have a good connection to vcenter
	if ! ret=$(${GOVC_EXE} about); then
		writeErr "could not connect to vcenter with provided info - ${ret}"
		echo "Writing current GOVC environment vars:"
		env | grep GOVC
		echo "Writing current certificate:"
		cat ${GOVC_TLS_CA_CERTS}
		return 1;
	fi

	if [[ ${ret} == *"specify an"* ]]; then
		writeErr "${ret}"
		return 1;
	fi

	#for running subshell commands within timeout function
	typeset -fx getInfo
	typeset -fx getPowerState
	typeset -fx getToolsStatus
	typeset -fx getToolsVersionStatus

	return 0
}

######################################
# Description: 
#   Try to get the vcenter certificate by download.
# Arguments:
#    vcenter_host
#######################################
function downloadVCCertificate(){
	local vcenter_host="${1}"

	if ! curl -LOJks https://${vcenter_host}/certs/download.zip; then
		writeErr "Could not retrieve vcenter certificate at https://${vcenter_host}/certs/download.zip"
		return 1
	fi

	if ! unzip -qq download.zip; then
		writeErr "Could not extract downloaded zip"
		return 1
	fi

	if [[ ! -d "certs/lin" ]]; then
		writeErr "Could not find linux certificate folder"
		return 1
	fi

	if ! certs=( certs/lin/*.0 ); then
		writeErr "Could not find a valid certificate"
		return 1
	fi
	
	#return first certificate found
	echo "${certs[0]}"

	return 0
}
######################################
# Description:
#
# Arguments:
#
#######################################
function powershellCmd() {
	local vm_ipath="${1}"
	local vm_username="${2}"
	local vm_password="${3}"
	local script="${4}"

	echo "Running PS: ${script}"

	local cmd="C:\\Windows\\System32\\WindowsPowerShell\\V1.0\\powershell.exe -NoProfile -Command \"${script}\""
	
	#echo "${GOVC_EXE} guest.start -vm.ipath=\"${vm_ipath}\" -l="${vm_username}:${vm_password}" ${cmd}"
	if ! pid=$(${GOVC_EXE} guest.start -vm.ipath="${vm_ipath}" -l="${vm_username}:${vm_password}" ${cmd} 2>&1); then
		echo "${pid}"
		writeErr "could not run powershell command on VM at ${vm_ipath}"
		return 1
	fi

	if ! processInfo=$(${GOVC_EXE} guest.ps -vm.ipath="${vm_ipath}" -l="${vm_username}:${vm_password}" -p=${pid} -X=true -x -json 2>&1); then
		echo "${processInfo}"
		writeErr "could not get powershell process ${pid} info on VM at ${vm_ipath}"
		return 1
	fi

	if ! exitCode=$(echo "${processInfo}" | jq '.ProcessInfo[0].ExitCode'); then
		echo "${exitCode}"
		writeErr "process info not be parsed for powershell command on VM at ${vm_ipath}"
		return 1
	fi

	echo "${exitCode}"
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function insertFloppy() {
	local vm_name="${1}"
	local datastore_name="${2}"
	local floppy_img_ds_path="${3}"

	if ! info=$(${GOVC_EXE} datastore.info -json ${datastore_name}); then
		writeErr "Could not get datastore info at ${datastore_name}"
		return 1
	fi

	if ! ${GOVC_EXE} device.floppy.add -vm="${vm_name}"; then
		writeErr "Could not add floppy drive to ${vm_name}"
		return 1
	fi

	if ! ${GOVC_EXE} device.floppy.insert -vm="${vm_name}" -ds="${datastore_name}" "${floppy_img_ds_path}"; then
		writeErr "Could not insert floppy file ${floppy_img_ds_path} into ${vm_name}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function mkdir() {
	local vm_ipath="${1}"
	local vm_username="${2}"
	local vm_password="${3}"
	local folder_Path="${4}"

	if ! ${GOVC_EXE} guest.mkdir -vm.ipath="${vm_ipath}" -l=${vm_username}:${vm_password} "${folder_Path}"; then
		writeErr "Could not make dir on VM at ${vm_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function clonevm() {
	local vm_name="${1}"
	local vm_datastore="${2}"
	local vm_folder=${3}
	local vm_host="${4}"
	local vm_resource_pool="${5}"
	local vm_network="${6}"
	local vm_cpu="${7}"
	local vm_memory_mb="${8}"
	local clone_vm_name="${9}"

	#if ! folderIPath=$(buildIpath "${vm_datacenter}" "${vm_folder}"); then echo ${folderIPath}; return 1; fi
	#if ! folderExists=$(folderExists "${folderIPath}"); then echo ${folderExists}; return 1; fi

	#if [[ ${folderExists} == "false" ]]; then
	#	if ! createFolder "${folderIPath}"; then return 1; fi
	#fi

	args="-m=${vm_memory_mb} -c=${vm_cpu} -on=false -force=true -annotation='Windows cloned VM.' -ds='${vm_datastore}' -folder='${vm_folder}' -host='${vm_host}' -net='${vm_network}' -vm='${clone_vm_name}'"

	[[ ! -z ${vm_resource_pool} ]] && args="${args} -pool='${vm_resource_pool}'"

	cmd="${GOVC_EXE} vm.clone ${args} ${vm_name}" #finally add the VM name

	echo ${cmd} #for reference
	if ! eval "${cmd}"; then
		writeErr "Could not clone VM ${clone_vm_name} as ${vm_name}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function resizeDisk() {
	local vm_ipath="${1}"
	local disk_size_gb="${2}"

	if ! ${GOVC_EXE} vm.disk.change -vm.ipath="${vm_ipath}" -size=${disk_size_gb}; then
		writeErr "Could not resize VM disk at ${vm_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function getInfo() {
	local vm_ipath="${1}"

	if ! info=$(${GOVC_EXE} vm.info -json -vm.ipath="${vm_ipath}"); then
		writeErr "Could not get vm info at ${vm_ipath}, ${info}"
		return 1
	fi

	echo "${info}"
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function getPowerState() {
	local vm_ipath="${1}"

	if ! info=$(getInfo "${vm_ipath}"); then
		echo "${info}"
		return 1
	fi # 2>&1

	if ! powerState=$(echo ${info} | jq '.VirtualMachines[0].Runtime.PowerState'); then
		writeErr "Could not parse vm info at ${vm_ipath}"
		return 1
	elif [[ -z "${powerState}" ]]; then
		writeErr "Power state could not be parsed for VM at ${vm_ipath}"
		return 1
	fi

	echo "${powerState}"
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function powerOnVM() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! ret=$(${GOVC_EXE} vm.power -vm.ipath="${vm_ipath}" -on=true -wait=true); then
		if [[ "${ret}" == *"current state (Powered on)"* ]]; then
			return 0
		else
			writeErr "Could not power on VM at ${vm_ipath}, ${ret}"
			return 1
		fi
	fi

	if [[ ${skip_toolstatus} -eq 1 ]]; then
		return 0
	fi

	if ! waitForToolStatus "${vm_ipath}" "${toolsOk}" ${timeout}; then
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
# | jq -r '.VirtualMachines[].Guest.ToolsStatus'
#######################################
function getToolsStatus() {
	local vm_ipath="${1}"

	if ! info=$(getInfo "${vm_ipath}"); then
		echo "${info}"
		return 1
	fi # 2>&1

	if ! toolsStatus=$(echo ${info} | jq -r '.VirtualMachines[].Guest.ToolsStatus'); then
		writeErr "Could not parse vm info at ${vm_ipath}"
		return 1
	elif [[ -z "${toolsStatus}" ]]; then
		writeErr "Tools state could not be parsed for VM at ${vm_ipath}"
		return 1
	fi

	echo "${toolsStatus}"
	return 0
}

######################################
# Description:
#
# Arguments:
# | jq -r '.VirtualMachines[].Guest.ToolsVersionStatus2'
#######################################
function getToolsVersionStatus() {
	local vm_ipath="${1}"

	if ! info=$(getInfo "${vm_ipath}"); then
		echo "${info}"
		return 1
	fi
	
	if ! toolsVersionStatus=$(echo ${info} | jq -r '.VirtualMachines[].Guest.ToolsVersionStatus2'); then
		writeErr "Could not parse vm info at ${vm_ipath}"
		return 1
	elif [[ -z "${toolsVersionStatus}" ]]; then
		writeErr "Tools version status could not be parsed for VM at ${vm_ipath}"
		return 1

		#info=$(${GOVC_EXE} vm.info -json "Win-Stemcell-Base")
		#echo $info
		#toolsVersionStatus=$(echo ${info} | jq -r '.VirtualMachines[].Guest.ToolsVersionStatus2')
	fi

	echo "${toolsVersionStatus}"
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function restartVM() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! ret=$(${GOVC_EXE} vm.power -vm.ipath="${vm_ipath}" -r=true -wait=true 2>&1); then
		writeErr "Could not restart VM at ${vm_ipath}, ${ret}"
		return 1
	fi

	if [[ ${skip_toolstatus} -eq 1 ]]; then
		return 0
	fi

	if ! waitForToolStatus "${vm_ipath}" "${toolsOk}" ${timeout}; then
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function connectDevice() {
	local vm_ipath="${1}"
	local device_name="${2}"

	if ! ${GOVC_EXE} device.connect -vm.ipath="${vm_ipath}" ${device_name}; then
		writeErr "Could not connect device to VM at ${vm_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function powerOffVM() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! ret=$(${GOVC_EXE} vm.power -vm.ipath="${vm_ipath}" -off=true -wait=true 2>&1); then
		writeErr "Could not power off VM at ${vm_ipath}, ${ret}"
		return 1
	fi

	if [[ ${skip_toolstatus} -eq 1 ]]; then
		return 0
	fi

	if ! waitForToolStatus "${vm_ipath}" "${toolsNotRunning}" ${timeout}; then
		return 1
	fi
	
	sleep 10 #There is a brief time between when the tools process is terminated and the VM is actually powered off

	return 0
}

######################################
# Description:
#
# Arguments:
#``````
#######################################
function shutdownVM() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! ret=$(${GOVC_EXE} vm.power -vm.ipath="${vm_ipath}" -s=true -wait=true 2>&1); then
		writeErr "Could not shutdown VM at ${vm_ipath}, ${ret}"
		return 1
	fi

	if [[ ${skip_toolstatus} -eq 1 ]]; then
		return 0
	fi

	if ! waitForToolStatus "${vm_ipath}" "${toolsNotRunning}" ${timeout}; then
		return 1
	fi

	sleep 10 #There is a brief time between when the tools process is terminated and the VM is actually powered off

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function waitForToolStatus(){
	local vm_ipath="${1}"
	local desired_status="${2:-"${toolsOk}"}" #toolsNotRunning
	local timeout=${3:-30s} #is a floating point number with an optional suffix: 's' for seconds (the default), 'm' for minutes, 'h' for hours or 'd' for days.  A duration of 0 disables the associated timeout.
	local sleep_time=${4:-5s}
	
	if [[ ("${desired_status}" == *"${toolsOk}"*) ]]; then
		desired_status="${toolsOk}|${toolsOld}"
	fi

	echo "Waiting for a tool status of ${desired_status}"
	echo -ne "|"

	set +e #turn "exit on error" off so we can catch the timeout
	
	timeout --foreground ${timeout} bash -c 'while [[ ! $(getToolsStatus "'${vm_ipath}'") =~ ^('${desired_status}')$ ]]; do echo -ne "."; sleep '${sleep_time}'; done'

	if [[ $? == 124 ]]; then
		echo ""
		writeErr "Timed out waiting for tool status of ${desired_status}. Last reported status was $(getToolsStatus ${vm_ipath})."
		return 1
	fi

	set -e

	echo "|"

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function validateToolsVersionStatus(){
	local vm_ipath="${1}"
	local vmware_tools_status=${2:-"${toolStatusCurrent}"}

	if ! toolStatus=$(getToolsStatus "${vm_ipath}"); then
		writeErr "Could not get tool status for VM at path ${vm_ipath}, ${toolStatus}"
		return 1
	fi

	echo "Current tools status: ${toolStatus}"

	if [[ "${toolStatus}" == *"${toolsNotInstalled}"* ]]; then
		writeErr "VMware tools are not installed on VM at path ${vm_ipath}. If the VM has no public access to download tools, use the vmware-tools-uri var to provide an internal place to download from."
		return 1
	fi

	#if the VM is not running, there is a chance no version status will be reported
	#if [[ "${toolStatus}" == *"${toolsNotRunning}"* ]]; then
	#	return 0
	#fi

	if ! toolVersionStatus=$(getToolsVersionStatus "${vm_ipath}"); then
		writeErr "Could not get tool version status for VM at path ${vm_ipath}, ${toolVersionStatus}"
		return 1
	fi

	echo "Current tools version status: ${toolVersionStatus}"

	echo "vmware-tools-status setting: ${vmware_tools_status}"

	if [[ "${toolVersionStatus}" != *"${guestToolsCurrent}"* ]]; then
		if [[ ("${vmware_tools_status}" == *"${toolStatusCurrent}"*) && ("${toolVersionStatus}" == *"${guestToolsSupportedOld}"*) ]]; then
			writeErr "Tools are installed but running an old version. Use the vmware-tools-uri var to provide up to date install or change the vmware-tools-status value."
			return 1
		elif [[ ("${vmware_tools_status}" == *"${toolsStatusSupported}"*) && ("${toolVersionStatus}" == *"${guestToolsSupportedOld}"*) ]]; then
			echo "VMware tools are running an old version but still compatible with the ESXi host, continuing."
		else
			writeErr "VMware tools status is being reported in a bad state, no other details are available. Verify the version installed is compatible with the ESXi host it is on in vCenter."
			return 1
		fi
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function buildIpath() {
	local vm_datacenter="${1}"
	local vm_folder=${2}
	local vm_name="${3}"

	if [[ -z ${vm_folder} ]]; then
		if [[ -z ${vm_name} ]]; then
			writeErr "VM name required if no folder name is provided"
			return 1
		fi

		echo "/${vm_datacenter}/vm/${vm_name}"
	else
		if [[ -z ${vm_name} ]]; then
			echo "/${vm_datacenter}/vm/${vm_folder}"
		else
			echo "/${vm_datacenter}/vm/${vm_folder}/${vm_name}"
		fi
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function vmExists() {
	local vm_ipath="${1}"

	if ! info=$(${GOVC_EXE} vm.info -json -vm.ipath="${vm_ipath}" 2>&1); then
		if [[ "${info}" == *"no such VM"* ]]; then
			echo false
			return 0
		else
			writeErr "${info}"
			return 1
		fi
	fi

	echo true
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function validateAndPowerOn() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! powerState=$(getPowerState ${vm_ipath}); then
		echo "${powerState}"
		return 1
	fi

	if [[ ! ${powerState} == *"poweredOn"* ]]; then
		if ! powerOnVM "${vm_ipath}" ${timeout} ${skip_toolstatus}; then return 1; fi
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function validateAndPowerOff() {
	local vm_ipath="${1}"
	local timeout=${2:-30s}
	local skip_toolstatus=${3:-0}

	if ! powerState=$(getPowerState ${vm_ipath}); then
		echo "${powerState}"
		return 1
	fi

	if [[ ! "${powerState}" == *"poweredOff"* ]]; then
		if ! powerOffVM "${vm_ipath}" ${timeout} ${skip_toolstatus}; then return 1; fi
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function uploadToDatastore() {
	local file_path="${1}"
	local datastore_name="${2}"
	local saveas_file_path="${3}"

	if ! info=$(${GOVC_EXE} datastore.info -json ${datastore_name}); then
		writeErr "Could not get datastore info at ${datastore_name}"
		return 1
	fi

	if ! ${GOVC_EXE} datastore.upload -ds=${datastore_name} ${file_path} ${saveas_file_path}; then
		writeErr "Could not upload file as ${saveas_file_path} to datastore ${datastore_name}"
		return 1
	fi

	return 0
}

######################################
# Description:
# 	Gracefully try to remove the VM. If it doesn't exist continue on, if it does check for errors.
# Arguments:
#
#######################################
function destroyVM() {
	local vm_ipath="${1}"

	if ! ret=$(${GOVC_EXE} vm.destroy -vm.ipath="${vm_ipath}" 2>&1); then
		if [[ "${ret}" == *"no such VM"* ]]; then
			return 0
		else
			writeErr "${info}"
			writeErr "Could not destroy VM at ${vm_ipath}"
			return 1
		fi
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function folderExists() {
	local folder_ipath="${1}"

	if ! info=$(${GOVC_EXE} folder.info -json "${folder_ipath}" 2>&1); then
		if [[ "${info}" == *"not found"* ]]; then
			echo false
			return 0
		else
			writeErr "${info}"
			return 1
		fi
	fi

	echo true
	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function createFolder() {
	local folder_ipath="${1}"

	if ! ${GOVC_EXE} folder.create "${folder_ipath}"; then
		writeErr "Could not create folder at ${folder_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function createVMwithISO() {
	local vm_name="${1}"
	local vm_datastore="${2}"
	local vm_host="${3}"
	local vm_network="${4}"
	local vm_cpu="${5}"
	local vm_memory_mb="${6}"
	local vm_disk_gb="${7}"
	local vm_folder="${8}"
	local vm_guest_os_id="${9}"
	local iso_datastore="${10}"
	local iso_path_in_datastore="${11}"
	local vm_net_adapter="${12}"
	local esxi_version="${13}"
	local firmware_type="${14}"
	local disk_controller_type="${15}"
	local vm_resource_pool="${16}"
	local vm_datacenter="${17}"

	if ! folderIPath=$(buildIpath "${vm_datacenter}" "${vm_folder}"); then
		echo ${folderIPath}
		return 1
	fi
	if ! folderExists=$(folderExists "${folderIPath}"); then
		echo ${folderExists}
		return 1
	fi

	if [[ ${folderExists} == "false" ]]; then
		if ! createFolder "${folderIPath}"; then return 1; fi
	fi

	args="-m=${vm_memory_mb} -c=${vm_cpu} -g='${vm_guest_os_id}' -link=false -on=false -force=false -annotation='Windows base VM for Pivotal products running .NET workloads.' -disk.controller='${disk_controller_type}' -firmware='${firmware_type}' -version='${esxi_version}' -net.adapter='${vm_net_adapter}' -disk='${vm_disk_gb}gb' -iso='${iso_path_in_datastore}' -iso-datastore='${iso_datastore}' -ds='${vm_datastore}' -folder='${vm_folder}' -host='${vm_host}' -net='${vm_network}'"

	[[ ! -z ${vm_resource_pool} ]] && args="${args} -pool='${vm_resource_pool}'"
	#[[ ! -z ${vm_cluster} ]] && args="${args} -datastore-cluster='${vm_cluster}'"

	cmd="${GOVC_EXE} vm.create ${args} ${vm_name}" #finally add the VM name

	#echo ${cmd} #for reference
	if ! eval ${cmd}; then
		writeErr "Could not create VM ${vm_name}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function setBootOrder() {
	local vm_ipath="${1}"

	if ! ${GOVC_EXE} device.boot -order=cdrom,disk -vm.ipath="${vm_ipath}"; then
		writeErr "Could not set boot order at ${vm_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description:
#
# Arguments:
#
#######################################
function ejectCDRom() {
	local vm_ipath="${1}"

	if ! ${GOVC_EXE} device.cdrom.eject -vm.ipath="${vm_ipath}"; then
		writeErr "Could not eject CD at ${vm_ipath}"
		return 1
	fi

	return 0
}

######################################
# Description: Ejects and removes the floppy and drive
#
# Arguments: The VM inventory path
#
#######################################
function ejectAndRemoveFloppyDrive() {
	local vm_ipath="${1}"

	id="$(${GOVC_EXE} device.ls -vm.ipath="${vm_ipath}" | grep -o '^floppy-[0-9]*')"

	if ! ${GOVC_EXE} device.floppy.eject -vm.ipath="${vm_ipath}" -device ${id}; then
		writeErr "Could not eject floppy at ${vm_ipath}"
		return 1
	fi

	if ! ${GOVC_EXE} device.remove -vm.ipath="${vm_ipath}" ${id}; then
		writeErr "Could not remove floppy at ${vm_ipath}"
		return 1
	fi

	return 0
}
