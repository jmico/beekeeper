#!/usr/bin/perl -wT

use strict;
use warnings;

use MyClient;

my $str = MyClient->uppercase( "Hello!" );

print "$str\n";
