# Shared key script for demo/record.sh; expects k() and type_slow() to be defined.
sleep 1.5
k 3G; sleep 0.5; k V; sleep 0.3; k 14G; sleep 0.9
k Space k; sleep 1.0
type_slow "validate the port range and document user"
sleep 0.6; k Enter
sleep 8.5
k a; sleep 1.8
k r; sleep 1.8
k a; sleep 2.2
k u; sleep 2.2
