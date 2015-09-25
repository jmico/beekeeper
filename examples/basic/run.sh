#!/bin/bash

EXAMPLE_DIR=$(readlink -f -n $(dirname "${BASH_SOURCE[0]}"))
PROJECT_DIR=$(readlink -f -n "$EXAMPLE_DIR/../../")

# Tell beekeeper to use the example config files
export BEEKEEPER_CONFIG_DIR="$EXAMPLE_DIR/config"
echo "Using config from  $BEEKEEPER_CONFIG_DIR"

# Allow perl to find the example modules 
export PERL5LIB="$EXAMPLE_DIR/lib":"$PROJECT_DIR/lib"
echo "Using modules from $PERL5LIB"

# Start the worker pool
$PROJECT_DIR/bin/bkpr --pool-id "myapp" --foreground start &

# Run the example script
perl $EXAMPLE_DIR/basic.pl
