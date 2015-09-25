#!/usr/bin/perl

use strict;
use warnings;

use MyClient;

my $str = MyClient->uppercase( "hello" );

print "$str\n";
