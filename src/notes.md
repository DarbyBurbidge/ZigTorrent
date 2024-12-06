###
ZigTorrent

#### Control Flow

on startup:
1. walk through files in a given folder and begin download/upload of files.

2. maintain an asynchronous menu whereby the user can view files in progress and their status.

3. menu should automatically refresh periodically and load newly added torrent files.

4. user can close client to stop current downloads/uploads.


#### Notes
* needs two folders, a folder for torrent files, and a destination folder for downloads.
* need a way to make sure files don't get corrupted on closing the client.

#### Technical Notes
* Can run on TCP
* Parse .torrent File (Bencode)
* Needs to connect to tracker
* Connect to and manage peers
* Choke/Unchoke
* Download/Upload
* Refresh and auto-load new torrent files
* Menu System
##### Optionals
* Support Magnets
* Support uTP

#### Resources
Creating a Bittorrent client using Asyncio:
https://www.youtube.com/watch?v=Pe3b9bdRtiE

WebTorrent: How I built a BitTorrent client in the browser:
https://www.youtube.com/watch?v=3w_6dfqrpzk&t=566s

Building a BitTorrent client from the ground up in Go:
https://blog.jse.li/posts/torrent/

Bittorrent.org and it's BEP listings:
https://www.bittorrent.org/beps/bep_0003.html

Browseable Zig stdlib:
https://ratfactor.com/zig/stdlib-browseable2/

Zig github:
https://github.com/ziglang/zig/tree/master/

Zig Official Documentation:
https://ziglang.org/documentation/master/std/

How to for putting together socket connections in Zig:
https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/

Url Encoding:
https://www.w3schools.com/tags/ref_urlencode.ASP

Man Pages:
socket(2)

and a laundry list of Zig resources.

#### Difficulties
* write UDP utils because zig only has library support for tcp at the moment. (scrapped)
* Something called Fortigate 
* PSU Appears to block Bittorrent requests
* Trackers returning but no PeerList
* Accidental null bytes in Uri Encoding
* Original Test file is larger than RAM capacity, I could write a system to utilize swap, or find a different test file (went with a torrent for debian ~660MB)
* issue with multithreading where I accidentally passed in a reference to a temp variable. I was using it to spawn threads and things looked fine, but all of the responses said they were coming from the same ip address (overwrote the peer struct and it's ip address)



#### Test files
Hashed Info for PoE1 File: 6d621051d4e4e3e73d07223ec28f39a00b34fcb9

