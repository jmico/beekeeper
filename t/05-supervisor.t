#!/usr/bin/env perl -T

use strict;
use warnings;

use lib 't/lib';
use Tests::Supervisor;

Tests::Supervisor->runtests;
