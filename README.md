# stor

Stor is a bash script to create and manage single-file filesystems with optional encryption (luks provided through cryptsetup)


See `stor.sh -h` for a full list of commands and details



### Creating a stor filesystem

To create a stor filesystem, simply run `stor create [size] [type] [file]:`

- To create a 128MB plain ext4 filesystem: `stor create 128M plain ./sample.plain`
- To create a 2GB luks encrypted filesystem: `stor create 2G vault ./sample.vault`



### Managing stor filesystems

Stor keeps track of mounted files that were mounted using `stor mount [file]`.
To unmount a file, get it's id from `stor ls` and unmount it using `stor umount [id]`.
To rename the ext4 filesystem on a stor file, you can use `stor rename [file]`.




### Important notes
 - Sizes <2MB may fail on some systems since the storage file will be formatted as ext4; sizes >16MB should be safe on all distros
 - Automounting assumes that the directory /media exists and is writable by the executing user
 - Storage file size is limited by the maximum file size of the underlying filesystem
 - This script needs write access to /var/run - run as root or adjust dir permissions accordingly
 - This script is intended for linux distros only


### License

[The Unlicense](https://unlicense.org)