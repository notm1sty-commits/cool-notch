#!/usr/bin/perl
# Запускает помощник Halo (libCoolNotchMediaBridge.dylib) внутри системного perl,
# чтобы читать «Что играет» на macOS 15.4+. Подробности — в Helpers/MediaBridge/MediaBridge.m.
use strict;
use warnings;
use DynaLoader;

my $library = shift @ARGV or die "usage: media-bridge.pl <path-to-dylib>\n";
my $handle = DynaLoader::dl_load_file($library, 0)
    or die "Cannot load $library: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "coolnotch_bridge_run")
    or die "Symbol not found: " . DynaLoader::dl_error() . "\n";
my $run = DynaLoader::dl_install_xsub("main::coolnotch_bridge_run", $symbol);
&$run();
