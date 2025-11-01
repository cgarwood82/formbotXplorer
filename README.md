# Overview
This repo serves as a landing place for files that aren't in the main update manager
for the xplorer. Some of these files may be from the image, some may be from custom
configs that I later generate, but they aren't part of the update process. 

## Repo Structure

### NotMine
NotMine is currently for files and folders discovered that aren't part of update
manager. Ideally these would by synced with the upstream, but currently that isn't
possible. So as I discover them, I'll version them here for distribution. Licenes
are unknown currently, but the project is generally managed in the open. Will 
fix any licensing issues that are in violation with a git issue!

### scripts
Scripts are for any scripts that are used to manage files in this repo as well as 
manage backups of files. This is not part fo the base image of the project. 

### 01__User_Custom_CFG
Folder for custom things I build that I want included in klipper. This is part of
the base image of the project. 

### 02__Boards_Serials
Folder for managing serial numbers for boards used in the project. This is part of
the base image of the project. 