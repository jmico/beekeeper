#!/usr/bin/perl -wT

use strict;
use warnings;

use MyApp::Calculator;

my $expr = "2+2";

my $result = MyApp::Calculator->eval_expr( $expr );

print "$expr = $result\n";
