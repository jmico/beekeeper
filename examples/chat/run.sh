#!/usr/bin/env bash

if [ -z "$BEEKEEPER_CONFIG_DIR" ]; then
    echo "Before running this example you need to setup the enviroment with:"
    echo "source setup.sh"
    exit 
fi

case "${1-start}" in
    'start')
        bkpr --pool "myapp-broker" start
        bkpr --pool "myapp-A" start
        bkpr --pool "myapp-B" start
        ;;
    'stop')
        bkpr --pool "myapp-A" stop
        bkpr --pool "myapp-B" stop
        bkpr --pool "myapp-broker" stop
        ;;
    'restart')
        bkpr --pool "myapp-A" restart
        bkpr --pool "myapp-B" restart
        ;;
    *)
        echo -e "Usage: $0 [start|stop|restart]"
        ;;
esac
