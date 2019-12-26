#!/bin/bash


# NOTES:
# sizes < 2MB may fail on some systems, suggesting to use 16MB or bigger

# QUESTIONS:
# what happens if disk doesnt have enough storage space?
# how do we handle help output? want "help/-h/--help" AND "stor [help/-h/--help] category"


command -v cryptsetup >/dev/null 2>&1 || { echo >&2 "Could not find 'cryptsetup'. Aborting."; exit 1; }
command -v mkfs.ext4 >/dev/null 2>&1 || { echo >&2 "Could not find 'mkfs.ext4'. Aborting."; exit 1; }
command -v e2label >/dev/null 2>&1 || { echo >&2 "Could not find 'e2label'. Aborting."; exit 1; }
command -v mount >/dev/null 2>&1 || { echo >&2 "Could not find 'mount'. Aborting."; exit 1; }
command -v umount >/dev/null 2>&1 || { echo >&2 "Could not find 'umount'. Aborting."; exit 1; }
command -v dd >/dev/null 2>&1 || { echo >&2 "Could not find 'dd'. Aborting."; exit 1; }
command -v pv >/dev/null 2>&1 || { echo >&2 "Could not find 'pv'. Aborting."; exit 1; }
command -v file >/dev/null 2>&1 || { echo >&2 "Could not find 'file'. Aborting."; exit 1; }


#######################################################################
##                                                                   ##
## Validates provided arguments and allocates required disk space    ##
##                                                                   ##
#######################################################################
allocate_file () {
	STOR_UNIT=${1: -1};
	STOR_UNIT_COUNT=${1: : -1};
	STOR_FILE=$2;

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
	FD3=$(mktemp);
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
## Creates ext4 filesystem on file                                   ##
##                                                                   ##
#######################################################################
create_fs () {
	STOR_FILE=$1;
	echo "Creating filesystem";
	OUTPUT=$(mkfs.ext4 "$STOR_FILE" 2>&1);
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
	STOR_FILE=$1;
	STOR_NAME=$2;
	if [[ "$STOR_NAME" == *"ext4 filesystem data"* ]];then
		echo "Stor name cannot contain string 'ext4 filesystem data'"; return 1;
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
	STOR_FILE=$1;
	OUTPUT=$(file "$STOR_FILE");
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
## Mounts storage at path                                            ##
##                                                                   ##
#######################################################################
stor_mount () {
	STOR_FILE=$1;
	STOR_MOUNT_PATH=$2;
	OUTPUT=$(mount "$STOR_FILE" "$STOR_MOUNT_PATH" 2>&1);
	if [[ "$?" -eq 0 ]];then
		echo "Mounted storage to '$STOR_MOUNT_PATH'";
		return 0;
	else
		echo "$OUTPUT";
		echo "Failed to mount storage. Aborting.";
		return 1;
	fi
}


#######################################################################
##                                                                   ##
## Creates random directory in /media and mounts storage there       ##
##                                                                   ##
#######################################################################
stor_automount () {
	STOR_FILE=$1;
	STOR_MOUNT_PATH=$(mktemp -d /media/STOR_AUTOMOUNT_XXXXXXXXXXXXXXXXXXXXXXXX);
	if [[ "$?" -ne 0 ]]; then
		echo "$STOR_DIR";
		echo "Failed to create automount directory. Aborting.";
		return 1;
	fi
	OUTPUT=$(mount "$STOR_FILE" "$STOR_MOUNT_PATH");
	if [[ "$?" -ne 0 ]];then
		echo "$OUTPUT";
		echo "Failed to automount storage. Aborting.";
	fi
	echo "Mounted storage on '$STOR_MOUNT_PATH'";
	return 0;
}


# stor create <size> <type> <file> [name]
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
	elif [[ "$STOR_TYPE" == "vault" ]];then
# MISSING!
		echo >&2 "Sorry, this feature is not implemented yet.";
		exit 1;
	else
		echo >&2 "Expected type to be 'plain' or 'vault', got '$STOR_TYPE'. Aborting.";
		exit 1;
	fi

	exit 0;
fi


# stor rename <file> <name>
if [[ "$#" -eq 3 && "$1" == "rename" ]];then
	STOR_FILE=$2;
	STOR_NAME=$3;
	stor_rename "$STOR_FILE" "$STOR_NAME" || exit 1;
fi


# stor mount <file> [path]
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
			stor_automount "$STOR_FILE" || exit 1;
			exit 0;
		else
			stor_mount "$STOR_FILE" "$STOR_MOUNT_PATH" || exit 1;
			exit 0;
		fi
	fi

	# vault storage mounting
# MISSING!

	echo >&2 "Could not determine type of file. Aborting.";
	exit 1;
fi


# stor clean
if [[ "$#" -eq 1 && "$1" == "clean" ]];then
	OUTPUT=$(rm -r /media/STOR_AUTOMOUNT_* 2>&1);
	echo "Cleanup complete";
fi