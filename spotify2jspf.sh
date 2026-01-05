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

# _escape_quotes() { # turn " into \"
#     sed 's/"/\\"/g'
# }

_escape_lucene_special_chars() { # escape all special characters involved in Lucene search syntax
                                 # https://lucene.apache.org/core/4_3_0/queryparser/org/apache/lucene/queryparser/classic/package-summary.html#Escaping_Special_Characters
    sed 's/\([][+&|!(){}^"~*?:\/-]\)/\\\1/g'
}

_remove_lucene_special_chars() { # get rid of special chars altogether
    sed 's/\([][+&|!(){}^"~*?:\/-]\)//g'
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

_mb_fetch_recording_for_url() { # return MusicBrainz recording for the given spotify URL, if any
    spotify_track_url=$1
    query_opts=(url "resource=${spotify_track_url}" "inc=recording-rels+artist-credits")
    res=$(_musicbrainz_query "${query_opts[@]}") || return
    if (($(jq '.relations | length' <<<$res) >= 1)); then
        _dbg "DEBUG Got relations"
        # if we get multiple results, we'll assume the first one is desired
        jq -c '.relations[0].recording' <<<$res
    elif ((${HARD_FAIL:-1})); then
        mapfile -d '' curl_cmd < <(_mb_query_cmd "${query_opts[@]}")
        return $(_failmsg "      Zero matching MusicBrainz recordings for $spotify_track_url. Request='${curl_cmd[*]}'; Response='$res'")
    else
        return 1
    fi
}

_mb_fetch_recording_for_artist_and_title() { # return MusicBrainz recording for the given artist/title, if any
                                             # there may be multiples, in which case we give the first
    artist_name=$1
    song_title=$2
    query_opts=()
    transforms=(
        _escape_lucene_special_chars
        _remove_lucene_special_chars
    )
    # apply each available transform to the queries until we get something usable
    # 1. nothing (raw string equal to the actual artist+title, with only special chars escaped)
    # 2. remove special chars rather than escaping
    # TODO: try even harder, e.g. do a fuzzy search to get matches within some edit distance
    for transform in "${transforms[@]}"; do
        artist_query=$("$transform" <<<$artist_name)
        recording_query=$("$transform" <<<$song_title)
        query_opts=(recording "query=recording:\"$recording_query\" AND artist:\"$artist_query\"" "inc=artist-credits")
        res=$(_musicbrainz_query "${query_opts[@]}") || return
        if (($(jq '.count' <<<$res) >= 1)); then
            # search results are fuzzy, so we need to narrow down to the single one with an exact match, if any
            if mapped_recording_json=$(jq -c \
                --arg title "$song_title" \
                --arg artist_name "$artist_name" \
                '[.recordings[] | select(."title" == $title) | select(."artist-credit"[0].name == $artist_name)][0] | select(.)' <<<$res
            ); then
                if [[ $mapped_recording_json ]]; then
                    _dbg "DEBUG: Returning exact match recording json"
                    echo "$mapped_recording_json"
                    return
                fi
            else
                return 1
            fi
            # if we got inexact matches, we'll warn but return the first one anyway
            # this happens because:
            # - sometimes artist names are stylized differently across platforms (dift. case/punctuation)
            # - MusicBrainz only allows querying based on sub-strings of song titles;
            #   so e.g. recording:"Foobar" matches both "Foobar" and "Foobar (club mix)"
            _dbg "DEBUG: Returning first match recording json"
            jq -c '.recordings[0] | select(.)' <<<$res || return
            return
        fi
    done
    if ((${HARD_FAIL:-1})); then
        mapfile -d '' curl_cmd < <(_mb_query_cmd "${query_opts[@]}")
        return $(_failmsg "      Zero matching MusicBrainz recordings for $artist_name - $song_title. Request='${curl_cmd[*]}'; Response='$res'")
    fi
    return 1
}

_map_track() { # return MBID for the given artist/title/spotify URL, if any
    artist_name=$1
    song_title=$2
    spotify_track_url=$3
    HARD_FAIL=0 _mb_fetch_recording_for_url "$spotify_track_url" && return
    # if we got nothing for this URL, try searching by artist+title
    _mb_fetch_recording_for_artist_and_title "$artist_name" "$song_title"
}

# _mb_fetch_recording_info_for_mbid() { # get artist credits and song title for the given MBID
#     mbid=$1
#     query_opts=("recording/${mbid}" "inc=artist-credits")
#     _musicbrainz_query "${query_opts[@]}"
# }

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
        if mapped_recording_json=$(_map_track "$creator" "$title" "$spotify_track_url"); then
            _dbg "DEBUG: Mapped recording json=${mapped_recording_json}"
            mapped_track_mbid=$(jq -r '.id' <<<$mapped_recording_json)
            actual_artist_name=$(jq -r '."artist-credit"[0].name' <<<$mapped_recording_json)
            actual_song_title=$(jq -r '.title' <<<$mapped_recording_json)
            _dbg "DEBUG: Found MBID=$mapped_track_mbid"
            if [[ $actual_artist_name != $creator ]] || [[ $actual_song_title != $title ]]; then
                _msg "      WARNING: Inexact match for '$creator - $title' (found: '$actual_artist_name - $actual_song_title')"
                title=$actual_song_title
                creator=$actual_artist_name
            fi
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