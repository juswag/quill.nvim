#!/usr/bin/env bash
# sheet.sh NAME [N]: N evenly spaced frames of NAME.gif tiled 2 wide into NAME.sheet.png for review.
name=$1 n=${2:-6}
d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$name.gif")
rm -rf "/tmp/proof/.f-$name"; mkdir -p "/tmp/proof/.f-$name"
for i in $(seq 0 $((n-1))); do
  t=$(python3 -c "print(round($d*($i+0.5)/$n,2))")
  ffmpeg -loglevel error -y -ss "$t" -i "$name.gif" -frames:v 1 "/tmp/proof/.f-$name/$(printf %02d $i).png"
done
ffmpeg -loglevel error -y -pattern_type glob -i "/tmp/proof/.f-$name/*.png" -vf "scale=900:-1,tile=2x$(( (n+1)/2 ))" "$name.sheet.png"
echo "$name: ${d}s"
