#!/usr/bin/env bash

_usage() {
cat <<USAGE
spotify2jspf.sh - convert spotify export format to JSPF
usage:
  spotify2jspf.sh [-h|-v] [IN] [OUT]
options:
  -v|--verbose  produce additional debugging output
  -h|--help     display this message and exit
arguments:
  IN            path to the Playlist1.json file to parse
                (default: ./Playlist1.json)
  OUT           path to a directory into which resulting .jspf files will be dumped
                (default: ./out)
USAGE
}

_percent_encode_unsafe_chars() {
    sed 's:/:%2F:g' | sed 's/:/%3A/g'
}

verbose=""
in_file=""
out_dir=""

while (($#)); do
    case $1 in
        (-h|--help)
            _usage
            exit
            ;;
        (-v|--verbose)
            verbose=1
            ;;
        (+v|--noverbose)
            verbose=""
            ;;
        (-*)
            >&2 echo "ERROR: Unrecognized option: $1"
            exit 1
            ;;
        (*)
            if [[ $out_dir ]]; then
                >&2 echo "ERROR: Unexpected argument after OUT: $1"
                exit 1
            elif [[ $in_file ]]; then
                out_dir=$1
            else
                in_file=$1
            fi
    esac
    shift
done

if [[ $verbose ]]; then
    _msg () {
        >&2 echo "$*"
    }
else
    _msg () { :; }
fi

_failmsg () {
    _msg "$@"
    echo 1
}

if [[ -z $in_file ]]; then
    in_file="./Playlist1.json"
fi
if [[ -z $out_dir ]]; then
    out_dir="./out"
fi
if ! [[ -f $in_file ]]; then
    >&2 echo "ERROR: Input file $in_file does not exist."
    exit 1
fi
if ! mkdir -p $out_dir; then
    >&2 echo "ERROR: Failed to create output directory $out_dir."
    exit 1
fi

playlist_dicts=()

mapfile playlist_dicts < <(jq -c '.playlists[]' "$in_file")

_map_track() { # return MBID for the given spotify URL, if any
    spotify_track_url=$1
    curl_cmd=(curl -s "https://musicbrainz.org/ws/2/url?fmt=json&resource=${spotify_track_url}&inc=recording-rels")
    for ii in {1..5}; do
        # up to 5 tries in case we get some network issues
        res=$("${curl_cmd[@]}")
        curl_rc=$?
        ((curl_rc)) || break
    done
    ((curl_rc)) && return $(_failmsg "      MusicBrainz database query failed. Request='${curl_cmd[*]}'; Response (rc=$curl_rc)='$res'")
    # if we got nothing for this URL, give up
    #COMBAK: try harder (look up by artist/title e.g.)
    (($(jq '.relations | length' <<<$res) >= 1)) || return $(_failmsg "      Zero back-links found for spotify track URL: ${spotify_track_url}. MusicBrainz recording query result: ${res}")
    # if we get multiple results, we'll assume the first one is desired
    jq -r '.relations[0].recording.id' <<<$res
}

for playlist_json in "${playlist_dicts[@]}"; do
    name_raw=$(jq -r .name <<<$playlist_json)
    name=$(_percent_encode_unsafe_chars <<<$name_raw)
    out_fn="${out_dir}/${name}.jspf"
    ii=1
    while [[ -e $out_fn ]]; do
        out_fn="${out_dir}/${name} ($ii).jspf"
        ii=$((ii+1))
    done
    _msg "Processing playlist: $name_raw (file: $out_fn)"
    track_dicts=()
    mapfile track_dicts < <(jq -c '.items[]' <<<$playlist_json)
    mapped_tracks=()
    mapping_failures=()
    _msg "  Attempting to map ${#track_dicts[@]} tracks..."
    for track_json in "${track_dicts[@]}"; do
        # map each Spotify track ID to a MusicBrainz recording ID
        # (this is the "identifier" field)
        title=$(jq -r .track.trackName <<<$track_json)
        creator=$(jq -r .track.artistName <<<$track_json)
        added_at=$(jq -r .addedDate <<<$track_json)
        spotify_track_uri=$(jq -r .track.trackUri <<<$track_json)
        spotify_track_id=${spotify_track_uri##*:}
        spotify_track_url="https://open.spotify.com/track/${spotify_track_id}"
        display_name="$creator - $title"
        _msg "    MAPPING: $display_name (URL: $spotify_track_url)..."
        if mapped_track_mbid=$(_map_track "$spotify_track_url"); then
            mapped_tracks+=("$(jq -nc \
                --arg title "$title" \
                --arg identifier "$mapped_track_mbid" \
                --arg creator "$creator" \
                --arg added_at "$added_at" \
            '{
                "title": $title,
                "identifier": $identifier,
                "creator": $creator,
                "extension": {
                    "https://musicbrainz.org/doc/jspf#track": {
                        "added_at": $added_at,
                    },
                },
            }' <<<$track_json)")
            _msg "      SUCCESS"
        else
            _msg "      FAILURE"
        fi
    done
    _msg "  ...done. Mapped ${#mapped_tracks[@]} of ${#track_dicts[@]} tracks."
    >"$out_fn" jq '{
        "playlist" : {
            "extension" : {
                "https://musicbrainz.org/doc/jspf#playlist" : {
                    "last_modified_at": .lastModifiedDate,
                    "public": false,
                }
            },
            "date" : .lastModifiedDate,
            "title" : .name,
            "track" : $ARGS.positional,
        }
    }' --jsonargs "${mapped_tracks[@]}" <<<$playlist_json
done