# Spotify to JSPF Converter

This repo contains a script (`spotify2jspf.sh`) for converting playlists dumped by a Spotify data request to [JSPF](https://xspf.org/jspf) format, making them suitable for manual ingestion into [ListenBrainz](https://listenbrainz.org) e.g.

## Prerequisites

- [`jq`](https://jqlang.org/) must be installed and available on your system path
- [cURL](https://curl.se/) >= 7.18.0 must be installed
- You must have a spotify playlist dump (`Playlist1.json` file)

## Example Usage

```bash
spotify2jspf.sh -v "/path/to/Spotify Account Data/Playlist1.json" "/path/to/jspf_out" |& tee conversion.log
```

## Limitations

- All playlists are assumed to be private - you will need to make them public manually if desired.
- [MusicBrainz API rate limiting](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting) limits your IP address to 1 request per second, so the absolute top speed for this conversion process is one track per second. Exercise patience.
