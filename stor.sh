#!/bin/bash

# init
mkdir -p /var/run/stor
touch /var/run/stor/mounts

command -v cryptsetup >/dev/null 2>&1 || { echo >&2 "Could not find 'cryptsetup'. Aborting."; exit 1; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo >&2 "Could not find 'mkfs.ext4'. Aborting."; exit 1; }
command -v e2label >/dev/null 2>&1 || { echo >&2 "Could not find 'e2label'. Aborting."; exit 1; }
command -v mount >/dev/null 2>&1 || { echo >&2 "Could not find 'mount'. Aborting."; exit 1; }
command -v umount >/dev/null 2>&1 || { echo >&2 "Could not find 'umount'. Aborting."; exit 1; }
command -v dd >/dev/null 2>&1 || { echo >&2 "Could not find 'dd'. Aborting."; exit 1; }
command -v pv >/dev/null 2>&1 || { echo >&2 "Could not find 'pv'. Aborting."; exit 1; }
command -v file >/dev/null 2>&1 || { echo >&2 "Could not find 'file'. Aborting."; exit 1; }
command -v hexdump >/dev/null 2>&1 || { echo >&2 "Could not find 'hexdump'. Aborting."; exit 1; }


#######################################################################
##                                                                   ##
## Validates provided arguments and allocates required disk space    ##
##                                                                   ##
#######################################################################
allocate_file () {
	local STOR_UNIT=${1: -1};
	local STOR_UNIT_COUNT=${1: : -1};
	local STOR_FILE=$2;

	# unit can only be kb, mb or gb
	if [[ "$STOR_UNIT" != "M" && "$STOR_UNIT" != "G" ]];then
		echo >&2 "Size unit must be either 'M' or 'G'. Aborting."; return 1;
	fi

	# size must be > 0
	if [[ "$STOR_UNIT_COUNT" -lt 1 ]];then
		echo >&2 "Size cannot be less than 1. Aborting."; return 1;
	fi

	# refuse to overwrite existing file
	if [[ -f "$STOR_FILE" ]];then
		echo "Refusing to override existing file '$STOR_FILE'. Aborting."; return 1;
	fi

	# refuse to create stor on block device
	# this will prevent accidental disk overwriting with dd
	if [[ -b "$STOR_FILE" ]];then
		echo "Refusing to operate on block device '$STOR_FILE'. Aborting."; return 1;
	fi

	# create a new file descriptor (FD3) to catch command outputs without bloating console on success
	# the immediate rm call is deferred until the file descriptor is closed, which happens when the script exits or crashes
	local FD3=$(mktemp);
	if [[ "$?" -ne 0 ]];then
		echo "$FD3";
		echo >&2 "Failed to create temporary file"; return 1;
	fi
	exec 3>"$FD3";
	if [[ "$?" -ne 0 ]];then
		echo >&2 "Failed to create temporary file handle"; return 1;	
	fi
	rm "$FD3";

	# allocate required space
	echo "Allocating ${STOR_UNIT_COUNT}${STOR_UNIT} of disk space";
	dd if=/dev/zero bs=1"${STOR_UNIT}" count="${STOR_UNIT_COUNT}" 2>/dev/null | pv -s "${STOR_UNIT_COUNT}${STOR_UNIT}" | dd of="${STOR_FILE}" 2>&3;
	if [[ "$?" -ne 0 ]];then
		cat "$FD3";
		echo >&2 "Failed to allocate disk space. Aborting."; return 1;
	fi

	return 0;
}


#######################################################################
##                                                                   ##
## Overwrites luks device with zeroes to prevent data leaks          ##
##                                                                   ##
#######################################################################
luks_zero_device () {
	local STOR_UNIT=${1: -1};
	local STOR_UNIT_COUNT=${1: : -1};
	local STOR_FILE=$2;

	# create a new file descriptor (FD4) to catch command outputs without bloating console on success
	# the immediate rm call is deferred until the file descriptor is closed, which happens when the script exits or crashes
	local FD4=$(mktemp);
	if [[ "$?" -ne 0 ]];then
		echo "$FD4";
		echo >&2 "Failed to create temporary file"; return 1;
	fi
	exec 4>"$FD4";
	if [[ "$?" -ne 0 ]];then
		echo >&2 "Failed to create temporary file handle"; return 1;	
	fi
	rm "$FD4";
	
	# overwrite device
	echo "Overwriting luks device with zero";
	dd if=/dev/zero bs=1"${STOR_UNIT}" count="${STOR_UNIT_COUNT}" 2>/dev/null | pv -s "${STOR_UNIT_COUNT}${STOR_UNIT}" | dd of="${STOR_FILE}" 2>&4;
	if [[ "$?" -ne 0 ]];then
		cat "$FD4";
		echo >&2 "Failed to overwrite luks device. Aborting."; return 1;
	fi
	return 0;
}


#######################################################################
##                                                                   ##
## Creates ext4 filesystem on file                                   ##
##                                                                   ##
#######################################################################
create_fs () {
	local STOR_FILE=$1;
	echo "Creating filesystem";
	local OUTPUT=$(mkfs.ext4 "$STOR_FILE" 2>&1);
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo >&2; "Failed to create ext4 file system. Aborting."; return 1;
	fi
	return 0;
}


#######################################################################
##                                                                   ##
## Assigns label to ext4 filesystem                                  ##
##                                                                   ##
#######################################################################
stor_rename () {
	local STOR_FILE=$1;
	local STOR_NAME=$2;
	if [[ "$STOR_NAME" == *"ext4 filesystem data"* || "$STOR_NAME" == *"LUKS encrypted file"* ]];then
		echo "Stor name cannot contain strings 'ext4 filesystem data' or 'LUKS encrypted file'"; return 1;
	fi
	echo "Assigning name '$STOR_NAME' to storage";
	OUTPUT=$(e2label "$STOR_FILE" "$STOR_NAME" 2>&1);
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to assign name to storage"; return 1;
	fi
	return 0;
}


#######################################################################
##                                                                   ##
## Checks if file is ext4 filesystem                                 ##
## returns 0 if yes, 1 if not and 2 on error                         ##
##                                                                   ##
#######################################################################
stor_is_plain () {
	local STOR_FILE=$1;
	local OUTPUT=$(file "$STOR_FILE");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to check if file is plain stor. Aborting."; return 2;
	fi
	if [[ "$OUTPUT" == *"ext4 filesystem data"* ]];then
		return 0;
	fi
	return 1;
}


#######################################################################
##                                                                   ##
## Checks if file is luks storage                                    ##
## returns 0 if yes, 1 if not and 2 on error                         ##
##                                                                   ##
#######################################################################
stor_is_luks () {
	local STOR_FILE=$1;
	local OUTPUT=$(file "$STOR_FILE");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to check if file is plain stor. Aborting."; return 2;
	fi
	if [[ "$OUTPUT" == *"LUKS encrypted file"* ]];then
		return 0;
	fi
	return 1;
}


#######################################################################
##                                                                   ##
## Mounts storage at path                                            ##
##                                                                   ##
#######################################################################
stor_mount () {
	local STOR_FILE=$1;
	local STOR_MOUNT_PATH=$2;
	local OUTPUT=$(mount "$STOR_FILE" "$STOR_MOUNT_PATH" 2>&1);
	if [[ "$?" -eq 0 ]];then
		echo "Mounted storage to '$STOR_MOUNT_PATH'";
		return 0;
	else
		echo "$OUTPUT";
		echo "Failed to mount storage. Aborting.";
		return 1;
	fi
}


stor_umount () {
	local STOR_MOUNT_PATH=$1;
	local OUTPUT=$(umount "$STOR_MOUNT_PATH");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo >&2 "Failed to unmount $STOR_MOUNT_PATH. Aborting."; return 1;
	fi
	if [[ "$STOR_MOUNT_PATH" == *"STOR_AUTOMOUNT_"* ]];then
		rm -rf "$STOR_MOUNT_PATH"
	fi 
	return 0;
}


#######################################################################
##                                                                   ##
## Creates random directory in /media and mounts storage in it       ##
##                                                                   ##
#######################################################################
stor_automount () {
	local STOR_FILE=$1;
	local STOR_MOUNT_PATH=$(mktemp -d /media/STOR_AUTOMOUNT_XXXXXXXXXXXXXXXXXXXXXXXX);
	if [[ "$?" -ne 0 ]]; then
		echo "$STOR_DIR";
		echo "Failed to create automount directory. Aborting.";
		return 1;
	fi
	local OUTPUT=$(mount "$STOR_FILE" "$STOR_MOUNT_PATH");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to automount storage. Aborting.";
	fi
	echo "$STOR_MOUNT_PATH";
	return 0;
}


#######################################################################
##                                                                   ##
## Creates luks encryption layout on storage and prompts for pass    ##
##                                                                   ##
#######################################################################
luks_init () {
	local STOR_FILE=$1;
	cryptsetup -y -v -q luksFormat "$STOR_FILE";
	if [[ "$?" -ne 0 ]];then
		echo "Failed to create luks encryption on storage"; return 1;
	fi
	return 0;
}


#######################################################################
##                                                                   ##
## Generates a random string for use as filename for dev mapper      ##
##                                                                   ##
#######################################################################
stor_rand_string () {
	echo "STOR_"$(hexdump -n 16 -v -e '/1 "%02X"' -e '/16 "\n"' /dev/urandom);
	return 0;
}


#######################################################################
##                                                                   ##
## Opens a LUKS device from storage                                  ##
##                                                                   ##
#######################################################################
luks_open () {
	local STOR_FILE=$1;
	local STOR_DEV_ID=$2;
	local OUTPUT=$(cryptsetup -q luksOpen "$STOR_FILE" "$STOR_DEV_ID");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to open luks volume"; return 1;
	fi
	# unmount because gvfs automounts devices from /dev/mapper on some systems
	sleep 2;
	local IGNORE=$(umount -A -q "/dev/mapper/${STOR_DEV_ID}");
	return 0;
}


#######################################################################
##                                                                   ##
## Closes a LUKS device                                              ##
##                                                                   ##
#######################################################################
luks_close () {
	local STOR_DEV_ID=$1;
	echo "Syncing filesystem";
	sync;
	local OUTPUT=$(cryptsetup -q luksClose "$STOR_DEV_ID");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to close LUKS device"; return 1;
	fi
	return 0;
}


#######################################################################
##                                                                   ##
## Add mount info to db                                              ##
##                                                                   ##
#######################################################################
stor_db_add_mount () {
	local STOR_FILE=$1;
	local STOR_DEV_ID=$2;
	local STOR_MOUNT_PATH=$3;
	echo "${STOR_FILE}:${STOR_DEV_ID}:${STOR_MOUNT_PATH}" >> /var/run/stor/mounts
}


#######################################################################
##                                                                   ##
## Lists current mounts from db                                      ##
##                                                                   ##
#######################################################################
stor_db_list_mounts () {
	local COUNTER=1;
	while read -r line; do
		while IFS=':' read -ra chunks; do
			echo "#${COUNTER} ${chunks[0]} => ${chunks[2]}";
			COUNTER=$((COUNTER+1));
		done <<< $(echo "$line");
	done < "/var/run/stor/mounts";
}


#######################################################################
##                                                                   ##
## Get mount device id by line number                                ##
##                                                                   ##
#######################################################################
stor_db_get_mount_dev_id () {
	local STOR_LINE=$1;
	local COUNTER=1;
	while read -r line; do
		while IFS=':' read -ra chunks; do
			if [[ "$COUNTER" -eq "$STOR_LINE" ]];then
				echo "${chunks[1]}";
				return 0;
			fi
			COUNTER=$((COUNTER+1));
		done <<< $(echo "$line");
	done < "/var/run/stor/mounts";
	return 1;
}


#######################################################################
##                                                                   ##
## Get mount path by line number                                     ##
##                                                                   ##
#######################################################################
stor_db_get_mount_path () {
	local STOR_LINE=$1;
	local COUNTER=1;
	while read -r line; do
		while IFS=':' read -ra chunks; do
			if [[ "$COUNTER" -eq "$STOR_LINE" ]];then
				echo "${chunks[2]}";
				return 0;
			fi
			COUNTER=$((COUNTER+1));
		done <<< $(echo "$line");
	done < "/var/run/stor/mounts";
	return 1;
}


#######################################################################
##                                                                   ##
## Remove mount from db by line number                               ##
##                                                                   ##
#######################################################################
stor_db_remove_mount () {
	local STOR_LINE=$1;
	local TMPFILE=$(mktemp /var/run/stor/mounts.XXXXXXXXX);
	local COUNTER=1;
	if [[ "$?" -ne 0 ]];then
		echo "$TMPFILE";
		echo "Failed to create temp file. Aborting."; return 1;
	fi
	while IFS= read -r line; do
		while IFS=':' read -ra chunks; do
			if [[ "${chunks[0]}" != "" && "$COUNTER" -ne "$STOR_LINE" ]];then
				printf "%s:%s:%s\n" "${chunks[0]}" "${chunks[1]}" "${chunks[2]}" >> "$TMPFILE"; 
			fi
		done <<< $(echo "$line");
	done < "/var/run/stor/mounts";
	mv "$TMPFILE" /var/run/stor/mounts;
}


















#### App entrypoint ####

















#################################################
##                                             ##
## stor create <size> <type> <file> [name]     ##
##                                             ##
#################################################
if [[ "$#" -gt 3 && "$#" -lt 6 && "$1" == "create" ]];then
	STOR_SIZE=$2;
	STOR_TYPE=$3;
	STOR_FILE=$4;
	STOR_NAME=$5;

	if [[ "$STOR_TYPE" == "plain" ]];then
		allocate_file "$STOR_SIZE" "$STOR_FILE" || exit 1;
		create_fs "$STOR_FILE" || { rm "$STOR_FILE"; exit 1; }
		if [[ -n "$STOR_NAME" ]];then
			stor_rename "$STOR_FILE" "$STOR_NAME" || { rm "$STOR_FILE"; exit 1; }
		fi
		echo "Created plain storage at $STOR_FILE";
		exit 0;
	elif [[ "$STOR_TYPE" == "vault" ]];then
		allocate_file "$STOR_SIZE" "$STOR_FILE" || exit 1;
		echo "Initializing LUKS";
		luks_init "$STOR_FILE" || { rm "$STOR_FILE"; exit 1; }
		STOR_DEV_ID=$(stor_rand_string);
		echo "Opening LUKS device";
		luks_open "$STOR_FILE" "$STOR_DEV_ID" || { rm "$STOR_FILE"; exit 1; }
		create_fs "/dev/mapper/${STOR_DEV_ID}" || { rm "$STOR_FILE"; exit 1; }
		if [[ -n "$STOR_NAME" ]];then
			stor_rename "/dev/mapper/${STOR_DEV_ID}" "$STOR_NAME" || { rm "$STOR_FILE"; exit 1; }
		fi
		luks_zero_device "$STOR_SIZE" "$STOR_DEV_ID" || { rm "$STOR_FILE"; exit 1; }
		luks_close "$STOR_DEV_ID" || { rm "$STOR_FILE"; exit 1; }
		echo "Created encrypted vault storage at $STOR_FILE";
		exit 0;
	else
		echo >&2 "Expected type to be 'plain' or 'vault', got '$STOR_TYPE'. Aborting.";
		exit 1;
	fi
fi


#################################################
##                                             ##
## stor rename <file> <name>                   ##
##                                             ##
#################################################
if [[ "$#" -eq 3 && "$1" == "rename" ]];then
	STOR_FILE=$2;
	STOR_NAME=$3;
	stor_rename "$STOR_FILE" "$STOR_NAME" || exit 1;
fi


#################################################
##                                             ##
## stor mount <file> [path]                    ##
##                                             ##
#################################################
if [[ "$#" -gt 1 && "$#" -lt 4 && "$1" == "mount" ]];then
	STOR_FILE=$2;
	STOR_MOUNT_PATH=$3;
	
	# plain storage mounting
	stor_is_plain "$STOR_FILE";
	EXIT_CODE=$?;
	if [[ "$EXIT_CODE" -eq 2 ]];then
		echo >&2 "Failed to check if file '$STOR_FILE' is plain storage"; exit 1;
	fi
	if [[ "$EXIT_CODE" -eq 0 ]];then
		if [[ -z "$STOR_MOUNT_PATH" ]];then
			STOR_MOUNT_PATH=$(stor_automount "$STOR_FILE");
			if [[ "$?" -ne 0 ]];then
				echo "$STOR_MOUNT_PATH";
				echo "Failed to mount $STOR_FILE. Aborting.";
				exit 1;
			fi
			stor_db_add_mount $(readlink -m "$STOR_FILE") "" "$STOR_MOUNT_PATH";
			echo "Mounted $STOR_FILE at $STOR_MOUNT_PATH";
			exit 0;
		else
			stor_mount "$STOR_FILE" "$STOR_MOUNT_PATH" || exit 1;
			stor_db_add_mount $(readlink -m "$STOR_FILE") "" "$STOR_MOUNT_PATH";
			exit 0;
		fi
	fi

	stor_is_luks "$STOR_FILE";
	EXIT_CODE=$?;
	if [[ "$EXIT_CODE" -eq 2 ]];then
		echo >&2 "Failed to check if file '$STOR_FILE' is plain storage"; exit 1;
	fi
	if [[ "$EXIT_CODE" -eq 0 ]];then
		STOR_DEV_ID=$(stor_rand_string);
		echo "Opening LUKS device";
		luks_open "$STOR_FILE" "$STOR_DEV_ID" || exit 1;
		if [[ -z "$STOR_MOUNT_PATH" ]];then
			STOR_MOUNT_PATH=$(stor_automount "/dev/mapper/${STOR_DEV_ID}");
			if [[ "$?" -ne 0 ]];then
				echo "$STOR_MOUNT_PATH";
				echo "Failed to mount $STOR_FILE. Aborting";
				luks_close "$STOR_DEV_ID";
				exit 1;
			fi
			stor_db_add_mount $(readlink -m "$STOR_FILE") "$STOR_DEV_ID" "$STOR_MOUNT_PATH";
			echo "Mounted $STOR_FILE at $STOR_MOUNT_PATH";
			exit 0;
		else
			stor_mount "$STOR_FILE" "$STOR_MOUNT_PATH" || { luks_close "$STOR_DEV_ID"; exit 1; }
			stor_db_add_mount $(readlink -m "$STOR_FILE") "$STOR_DEV_ID" "$STOR_MOUNT_PATH";
			exit 0;
		fi
	fi
	echo >&2 "Could not determine type of file. Aborting.";
	exit 1;
fi


#################################################
##                                             ##
## stor umount <id>                            ##
##                                             ##
#################################################
if [[ "$#" -eq 2 && "$1" == "umount" ]];then
	STOR_DEV_ID=$(stor_db_get_mount_dev_id "$2");
	if [[ "$?" -ne 0 ]];then
		echo >&2 "Could not find entry #$2. Aborting."; exit 1;
	fi
	STOR_MOUNT_PATH=$(stor_db_get_mount_path $2);
	if [[ "$?" -ne 0 ]];then
		echo >&2 "Failed to get mount path for $2. Aborting."; exit 1;
	fi
	if [[ "$STOR_DEV_ID" == "" ]];then
		stor_umount "$STOR_MOUNT_PATH" || exit 1;
		stor_db_remove_mount $2;
		echo "Unmounted #$2";
		exit 0;
	else
		stor_umount "$STOR_MOUNT_PATH" || exit 1;
		luks_close "$STOR_DEV_ID" || exit 1; 
		stor_db_remove_mount $2;
		echo "Unmounted #$2";
		exit 0;
	fi

fi


#################################################
##                                             ##
## stor ls                                     ##
##                                             ##
#################################################
if [[ "$#" -eq 1 && "$1" == "ls" ]];then
	stor_db_list_mounts;
	exit 0;
fi


#################################################
##                                             ##
## stor help/-h/--help [command]               ##
##                                             ##
#################################################

# MISSING: ls, umount

if [[ "$1" == "help" || "$1" == "-h" || "$1" == "--help" ]];then

	if [[ "$#" -eq 1 ]];then
	echo "Usage: $0 command options...
For more detailed information, run '$0 help <command>'

$0 create <size> <type> <file> [name] - Create a new storage file
$0 rename <file> <name>               - Rename storage
$0 ls                                 - Show currently active mounts with ids
$0 mount <file> [path]                - Mount storage as filesystem
$0 umount <id>                        - Unmounts id
";
	elif [[ "$#" -eq 2 ]];then
		if [[ "$2" == "create" ]];then
echo "Usage: $0 create <size> <type> <file> [name]
Creates a storage file at <file>. Will fail if it already exists.

<size> is the size of the storage file in the format 16G. Supported are 'G' for GB and 'M' for MB.
<type> can be either 'plain' for simple ext4 or 'vault' for LUKS-encrypted ext4.
<file> the path where the file should be created
[name] optional, name of the ext4 filesystem
";
		elif [[ "$2" == "rename" ]];then
echo "Usage: $0 rename <file> <name>
Renames the ext4 filesystem on <file>

<file> file to rename
<name> new name for the ext4 filesystem
";
		elif [[ "$2" == "ls" ]];then
echo "Usage: $0 ls
Show currently active mounts with id
";
		elif [[ "$2" == "mount" ]];then
echo"Usage: $0 mount <file> [path]
Mounts the storage file

<file> file to mount
[path] optional, mount file at this path; if missing creates a random path at /media/STOR_AUTOMOUNT_*
";
		elif [[ "$2" == "umount" ]];then
echo "Usage: $0 umount <id>
Unmounts <id> from filesystem (and closes luks device if it is an encrypted filesystem)
";
		else
			echo "Unrecognized options. See $0 --help for help."; exit 1;
		fi
	else
		echo "Unrecognized options. See $0 --help for help."; exit 1;
	fi
	exit 0;
fi

echo "Unrecognized options. See $0 --help for help"; exit 1;