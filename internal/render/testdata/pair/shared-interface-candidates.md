### shared-interface-candidates:Shared/LikedSongs:Sources/LikedSongs/LikedSongSnapshot.swift:8:LikedSongSnapshot+Shared/Playlist:Sources/Playlist/PlaylistEntry.swift:12:Playcut

jacc=70%, intersection=7, union=10

- left:    Playcut (type-alias-object) — Shared/Playlist:Sources/Playlist/PlaylistEntry.swift:12
- right:   LikedSongSnapshot (type-alias-object) — Shared/LikedSongs:Sources/LikedSongs/LikedSongSnapshot.swift:8

- shared slots:      artistName:String, artworkURL:URL?, labelName:String?, releaseTitle:String?, songTitle:String, spotifyURL:URL?
- conflicting slots: id (UInt64 vs String)
- left fields:  artistName, artworkURL, hour, id, labelName, releaseTitle, songTitle, spotifyURL, timeCreated
- right fields: artistName, artworkURL, id, labelName, likedAt, releaseTitle, songTitle, spotifyURL
- left only:    hour, timeCreated
- right only:   likedAt

### shared-interface-candidates:Shared/FeedKit:Sources/FeedKit/CachedFeed.swift:5:CachedFeed+Shared/LiveKit:Sources/LiveKit/LiveFeed.swift:9:LiveFeed

jacc=71%, intersection=5, union=7, demoted=true

- left:    CachedFeed (type-alias-object) — Shared/FeedKit:Sources/FeedKit/CachedFeed.swift:5
- right: * LiveFeed (type-alias-object) — Shared/LiveKit:Sources/LiveKit/LiveFeed.swift:9

- shared slots:      etag:String?, items:[FeedItem], source:URL, ttl:Int, updatedAt:Date
- left fields:  etag, items, origin, source, ttl, updatedAt
- right fields: etag, items, socket, source, ttl, updatedAt
- left only:    origin
- right only:   socket
