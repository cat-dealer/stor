# stor

Stor is a bash script to create and manage single-file filesystems with optional encryption


### Important notes

 - Sizes <2MB may fail on some systems since the storage file will be formatted as ext4; i suggest using at least 16MB to be safe
 - Automounting assumes that the directory /media exists and is writable by the executing user
 - Storage file size is limited by the maximum file size of the underlying filesystem