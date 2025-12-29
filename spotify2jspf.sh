#!/usr/bin/env bash

_usage() {
cat <<USAGE
spotify2jspf.sh - convert spotify export format to JSPF
usage:
  spotify2jspf.sh [-h] [IN] [OUT]
options:
  -h|--help  display this message and exit
arguments:
  IN         path to the Playlist1.json file to parse
             (default: ./Playlist1.json)
  OUT        path to a directory into which resulting .jspf files will be dumped
             (default: ./out)
USAGE
}

in_file=""
out_dir=""

while (($#)); do
    case $1 in
        (-h|--help)
            _usage
            exit
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

for playlist_json in "${playlist_dicts[@]}"; do
    name=$(jq -r .name <<<$playlist_json | sed 's:/:%2F:g')
    out_fn="${out_dir}/${name}.jspf"
    ii=1
    while [[ -e $out_fn ]]; do
        out_fn="${out_dir}/${name} ($ii).jspf"
        ii=$((ii+1))
    done
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
            "track" : [ .items[] | 
                {
                    "title" : .track.trackName,
                    "creator" : .track.artistName,
                    "extension" : {
                    "https://musicbrainz.org/doc/jspf#track" : {
                        "added_at" : .addedDate,
                    }
                    },
                }
            ],
        }
    }' <<<$playlist_json
done