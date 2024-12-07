# [RFC WIP] ZigTorrent: CS494 Class Project Specification
Portland State University
December 6, 2024

**Author:**

- @Darby Burbidge

## 1 Executive Summary

The primary goal of this proposal is to build a BitTorrent Client in Zig using the BitTorrent v1.0 Spec:
https://www.bittorrent.org/beps/bep_0003.html
and
https://wiki.theory.org/BitTorrentSpecification
* This includes:
* reading in a .torrent file
* contacting a tracker and fetching peers
* connecting to those peers and passing messages
* downloading a file
* reconstituting that file
* breaking down a file
* uploading a file


## 2 Motivation

* The primary goal of this project is to better understand the Bittorrent Protocol.
* To better understand P2P networks in general
* To become more familiar with Zig.

## 3 Proposed Implementation

The proposed implementation involves scanning for torrent files and for each one spawning a FileManager thread:
```zig
const FileManager = struct {
    allocator: std.mem.Allocator,
    peer_id: [HASH_LEN]u8,
    t_file: Torrent.TorrentFile,
    f_file: std.fs.File.Stat,
    f_buf: []u8,
    f_bfield: BitField,
    peers: std.ArrayList(Peer),
    p_threads: std.ArrayList(std.Thread),
};
```
The file manager opens the torrent files, storing them in TorrentFile structs:
```zig
const TorrentFile = struct {
    announce: std.ArrayList([]const u8),
    comment: []u8,
    creation_date: u64,
    info_hash: [HASH_LEN]u8,
    length: u64,
    name: []u8,
    piece_length: u64,
    pieces: [][HASH_LEN]u8,
};
```
The FileManager then contacts the Tracker for the file, using http, and gets a list of peers:
```zig
const TrackerQuery = struct {
    info_hash: []u8,
    peer_id: []u8,
    port: u64,
    uploaded: u32,
    downloaded: u32,
    compact: u32,
    left: u64,
};

pub const TrackerResponse = struct {
    interval: u64,
    peers: ?[]Peer
};
```

```zig
const Peer = struct {
    allocator: std.mem.Allocator,
    ip: [HOST_SIZE]u8,
    port: u16,
    conn_stream: ?std.net.Stream,
    state: PeerState,
};
```
Each with their own state:
```zig
const PeerState = struct {
    choked: bool,
    interested: bool,
    am_choking: bool,
    am_interested: bool,
    peer_choking: bool,
    peer_interested: bool,
    b_field: ?BitField,
};
```
Once Peers have been gathered the FileManager initates the download process and contacts the peers setting up tcp connections.
This way they can communicate using PeerMessages:
```zig
pub const PeerMessage = struct {
    type: MessageType,
    piece_idx: ?u32,
    b_field: ?BitField,
    index: ?u32,
    begin: ?u32,
    length: ?u32,
    block: ?[]u8,
};

const MessageType = union(enum) {
    keep_alive,
    choke,
    unchoke,
    interested,
    not_interested,
    have,
    bitfield,
    request,
    piece,
    cancel,
};
```
As you can see there are 10 different message types that are supported.

The file manager then looks for work that needs to be done for the download using the bitfield of the files pieces. The File manager then tells that peer to request that information and return that piece of the file, spawning a thread so the peer is free to do so.

Once a piece is received, the File manager adds it to the file buffer.

Once the file buffer is complete, the FileManager then reconstitutes the file.

[Struct Chart](./flow_diagram.pdf)

## 4 Metrics & Dashboards

While Download and upload speeds are important metrics, other metrics that are important is response time for peers.
One of the reasons the proposal uses multithreading is that not every peer responds in a timely manner and to avoid other peers needing to wait on a slow peer, multithreading is used.

## 5 Drawbacks

There have been many drawbacks to this proposal.
* Lack of experience.
While I am comfortable coding, I have no prior experience implementing an existing protocol.
I definitely didn't fully understand the scope of what I would be taking on.
* BitTorrent has many additions and variations.
Not all of which this proposal is prepared to adopt.
* Interfacing with unknown devices.
My prior experience involved controlling both ends of communication. Not having insight into the other end of the connection made problem shooting abnormally difficult.
* Language Choice. 
Zig is still in development. Much of it's documentation is lacklustre at best and misleading at worst.

## 6 Alternatives

Virtually any other BitTorrent Client.

## 7 Potential Impact and Dependencies

Malicious actors would have another BitTorrent client to steal or pirate software and media.

Given the nature of it being developed in a maturing language there may be exploits in the networking interface/s that we are unaware of. Not to mention errors in our own code.

## 8 Unresolved questions

Future additions to this proposal would be to have it run as a Daemon, scanning for and loading drag-and-dropped .torrent files, allowing it to run in the background.
Another addition is utilizing uTP rather than TCP.

## 9 Conclusion

This proposal aims to provide a lightweight simple BitTorrent client to the library of existing clients out there. It's primary purpose is for personal and academic curiosity.
