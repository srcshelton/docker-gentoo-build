#! /usr/bin/env bash

# pipesort - perform a simple in-line sort/uniq operation, which outputs lines
#            if input if-and-only-if they differ from the previous line,
#            there-by allowing trivial sorts to be viewed more immediately.

if [[ " ${*:-} " =~ -(h|-help) ]]; then
	echo "Usage: echo <text> | $( basename "${0}" ) [--count]"
	exit 0
fi

declare -i count=0 firstline=1 o=0

if [[ " ${*:-} " =~ -(c|-count) ]]; then
	count=1
fi

declare lastline='' line=''

while read -r line; do
	if (( count )); then
		# Output a new line when the content changes
		if [[ "${line}" == "${lastline}" ]]; then
			(( o ++ ))
		else
			if (( firstline )); then
				firstline=0
			else
				# 'o' is numeric, so doesn't need quoting...
				# shellcheck disable=SC2086
				printf '%s (%d)\n' "${lastline}" ${o}
			fi
			lastline="${line}"
			o=0
		fi
	else
		# Output a new line as soon as we see it
		if ! [[ "${line}" == "${lastline}" ]]; then
			if (( firstline )); then
				firstline=0
			else
				printf '%s\n' "${line}"
			fi
			lastline="${line}"
		fi
	fi
done

if (( count )); then
	if [[ "${line}" == "${lastline}" ]]; then
		printf '%s (%d)\n' "${line}" ${o}
	fi
fi
