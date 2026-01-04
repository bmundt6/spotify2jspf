#!/usr/bin/env bash

_usage() {
cat <<USAGE
spotify2jspf.sh - convert spotify export format to JSPF
usage:
  spotify2jspf.sh [-h|-v [LEVEL]] [IN] [OUT]
options:
  -v|--verbose [LEVEL]  produce additional debugging output
                        LEVEL is an integer defining how verbose to be
                        (more is more)
  -h|--help             display this message and exit
arguments:
  IN                    path to the Playlist1.json file to parse
                        (default: ./Playlist1.json)
  OUT                   path to a directory into which resulting .jspf files will be dumped
                        (default: ./out)
USAGE
}

_percent_encode_unsafe_chars() { # sanitize stuff for the filesystem
    sed 's:/:%2F:g' | sed 's/:/%3A/g'
}

unset HARD_FAIL
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
            if (($# > 1)) && [[ $2 =~ ^[0-9]+$ ]]; then
                shift
                verbose=$1
            elif [[ $verbose ]]; then
                verbose=$((verbose + 1))
            else
                verbose=1
            fi
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

_msg () { :; }
_dbg () { :; }
if [[ $verbose ]]; then
    _msg () {
        >&2 echo "$*"
    }
    if ((verbose > 1)); then
        _dbg() { _msg "$@"; }
    fi
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

_mb_query_cmd() { # get the cURL command to use for a MusicBrainz API query (as a NUL delimited list)
                  # first argument is the top-level API request, like /artist /recording etc.
                  # following arguments are query string params
    req=$1; shift
    curl_cmd=(curl --get -s "https://musicbrainz.org/ws/2/${req}" --data-urlencode "fmt=json")
    while (($#)); do
        curl_cmd+=(--data-urlencode "$1")
        shift
    done
    printf "%s\0" "${curl_cmd[@]}"
}

_musicbrainz_query() { # make a request to the MusicBrainz API
                       # output format is always JSON
                       # first argument is the top-level API request, like /artist /recording etc.
                       # following arguments are query string params
    mapfile -d '' curl_cmd < <(_mb_query_cmd "$@")
    for ii in {1..5}; do
        # up to 5 tries in case we get some network issues
        _dbg "DEBUG Trying command $ii of 5 attempts: ${curl_cmd[*]}"
        res=$("${curl_cmd[@]}")
        curl_rc=$?
        ((curl_rc)) || break
    done
    ((curl_rc)) && return $(_failmsg "      MusicBrainz API query failed. Request='${curl_cmd[*]}'; Response (rc=$curl_rc)='$res'")
    _dbg "DEBUG Response: $res"
    echo "$res"
}

_mb_fetch_recording_for_url() { # return MBID for the given spotify URL, if any
    spotify_track_url=$1
    query_opts=(url "resource=${spotify_track_url}" "inc=recording-rels")
    res=$(_musicbrainz_query "${query_opts[@]}") || return
    if (($(jq '.relations | length' <<<$res) >= 1)); then
        _dbg "DEBUG Got relations"
        # if we get multiple results, we'll assume the first one is desired
        jq -r '.relations[0].recording.id' <<<$res
    elif ((${HARD_FAIL:-1})); then
        mapfile -d '' curl_cmd < <(_mb_query_cmd "${query_opts[@]}")
        return $(_failmsg "      Zero matching MusicBrainz recordings for $spotify_track_url. Request='${curl_cmd[*]}'; Response='$res'")
    else
        return 1
    fi
}

_mb_fetch_recording_for_artist_and_title() { # return MBID for the given artist/title, if any
                                             # there may be multiples, in which case we give the first
    artist_name=$1
    song_title=$2
    query_opts=(recording "query=recording:\"$song_title\" AND artist:\"$artist_name\"")
    res=$(_musicbrainz_query "${query_opts[@]}") || return
    if (($(jq '.count' <<<$res) >= 1)); then
        # search results are fuzzy, so we need to narrow down to the single one with an exact match, if any
        if mbid=$(jq -r \
            --arg title "$song_title" \
            --arg artist_name "$artist_name" \
            '[.recordings[] | select(."title" == $title) | select(."artist-credit"[].name == $artist_name) | .id][0]' <<<$res
        ); then
            if [[ $mbid ]]; then
                echo "$mbid"
                return
            fi
        else
            return 1
        fi
        # if we got inexact matches, then warn but return the first one anyway
        jq -r '.recordings[0].id' <<<$res || return
        _msg "      WARNING: Inexact match for $artist_name - $song_title"
        #TODO: try even harder
        # e.g. do a secondary fuzzy search to match Foo - Bartist remix as well as Foo (Bartist Remix)
    elif ((${HARD_FAIL:-1})); then
        mapfile -d '' curl_cmd < <(_mb_query_cmd "${query_opts[@]}")
        return $(_failmsg "      Zero matching MusicBrainz recordings for $artist_name - $song_title. Request='${curl_cmd[*]}; Response='$res'")
    else
        return 1
    fi
}

_map_track() { # return MBID for the given artist/title/spotify URL, if any
    artist_name=$1
    song_title=$2
    spotify_track_url=$3
    HARD_FAIL=0 _mb_fetch_recording_for_url "$spotify_track_url" && return
    # if we got nothing for this URL, try searching by artist+title
    _mb_fetch_recording_for_artist_and_title "$artist_name" "$song_title"
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
        _msg "    MAPPING: $creator - $title (URL: $spotify_track_url)..."
        if mapped_track_mbid=$(_map_track "$creator" "$title" "$spotify_track_url"); then
            musicbrainz_recording_url="https://musicbrainz.org/recording/${mapped_track_mbid}"
            mapped_tracks+=("$(jq -nc \
                --arg title "$title" \
                --arg identifier "$musicbrainz_recording_url" \
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