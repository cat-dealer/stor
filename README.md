# stor

Stor is a bash script to create and manage single-file filesystems with optional encryption (luks provided through cryptsetup)






### Important notes
 - Sizes <2MB may fail on some systems since the storage file will be formatted as ext4; sizes >16MB should be safe on all distros
 - Automounting assumes that the directory /media exists and is writable by the executing user
 - Storage file size is limited by the maximum file size of the underlying filesystem
 - This script is intended for linux distros and there are no plans to make it work in max, windows or other OS; you're welcome to fork this project and do it yourself though :)