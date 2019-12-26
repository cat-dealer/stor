# stor

Stor is a bash script to create and manage single-file filesystems with optional encryption


### Important notes

 - Sizes <2MB may fail on some systems since the storage file will be formatted as ext4
 - Automounting assumes that the directory /media exists and is writable by the executing user