#! /bin/sh

set -e

docker ps -a | tr -cd '[[:print:]\n]' | rev | cut -d' ' -f 1 | rev | grep '_' | xargs -r docker rm

docker image ls | grep '^<none>\s\+<none>' | awk '{ print $3 }' | xargs -r docker image rm

docker image ls --filter 'dangling=true' | tail -n +2 | awk '{ print $3 }' | xargs -r docker image rm
