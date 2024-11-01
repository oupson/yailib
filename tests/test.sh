#!/usr/bin/env sh

size=$(identify -ping -format '%wx%h' $1)
opaque=$(identify -format '%[opaque]' $1)

if [ $opaque = "True" ]; then
    input_format="RGB:-"
else
    input_format="RGBA:-"
fi

zig build run -- $1 | \
    magick -size $size -depth 8 $input_format png:- | \
    chafa
