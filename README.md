# Spotify to JSPF Converter

This repo contains a script (`spotify2jspf.sh`) for converting playlists dumped by a Spotify data request to [JSPF](https://xspf.org/jspf) format, making them suitable for manual ingestion into [ListenBrainz](https://listenbrainz.org) e.g.

## Prerequisites

- [`jq`](https://jqlang.org/) must be installed and available on your system path
- You must have a spotify playlist dump (`Playlist1.json` file)

## Example Usage

```bash
spotify2jspf.sh "/path/to/Spotify Account Data/Playlist1.json" "/path/to/jspf_out"
```

## Limitations

- All playlists are assumed to be private - you will need to make them public manually if desired.
- FIXME: `Error: JSPF playlist track 0 must contain a identifier field having a fully qualified URI to a recording_mbid. (e.g. https://musicbrainz.org/recording/8f3471b5-7e6a-48da-86a9-c1c07a0f47ae)`
