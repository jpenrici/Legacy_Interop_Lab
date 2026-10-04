#!/usr/bin/perl
# Objective:
#   Check for the existence of the files.
#   Compile C code.
use strict;
use warnings;

die "Refusing to run as root (uid 0). Re-run as a regular user.\n"
  if ( $< == 0 || $> == 0 );

print "=== C BUILD UTILITY ===\n\n";

# Define paths and file names based on the new hierarchy
my $bin_dir = "../bin";
my $src_dir = "./src";
my $c_file  = "$src_dir/main.c";
my $app_bin = "$bin_dir/main_c";

# 1. Check Source Code Files
die "[ERROR] C source file '$c_file' not found!\n" unless ( -e $c_file );
print "[OK] C source file '$c_file' verified.\n";

# 5. Compile C Program (requires 'gcc')
print "[BUILD] Compiling C program ($c_file)...\n";
my $c_result = system("gcc -std=c23 -o $app_bin $c_file");
if ( $c_result != 0 ) {
    die "[ERROR] C compilation failed. Make sure GCC is installed.\n";
}
print "[SUCCESS] C executable '$app_bin' generated successfully.\n";

print "\n=== BUILD COMPLETED SUCCESSFULLY ===\n";
