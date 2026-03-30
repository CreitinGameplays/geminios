[x] add a -adv (--advanced) flag to the gtop that will display more information and details (a bit like htop), make it beauty looking:
- CPU model name (with the max frequency, including turbo freq if possible)
- graphical per core usage, showing percentage and core temperature, current frequency, and voltage (if possible)
- graphical RAM usage, with the total, used, free, and available (with the percentage of each)
- graphical swap usage, with the total, used, free, and available (with the percentage of each)
- graphical disk usage, with the total, used, free, and available (with the percentage of each)
- graphical network usage, with the total, used, free, and available (with the percentage of each)
- graphical process usage, showing percentage and memory usage
- graphical GPU usage, showing percentage and memory usage, with the GPU model name (if possible here)
[x] add to gtop a -d (--delay) flag to set the delay between updates, default to 1 second
[x] clean up terminal just after the user login (`clear`)
[x] improve gpkg installing look to be like:
Downloading <package_name>
[===                      ] 10% (x/KBps/MBps/GBps)
Installing <package_name>
[===                      ] 10%
✓ Installed <package_name>
[x] Implement GPKG v2 (Structured packages, metadata, and repository system)
