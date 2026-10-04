#!/usr/bin/perl
# Objective:
#   Check for the existence of the files.
#   Compile COBOL code.
use strict;
use warnings;

die "Refusing to run as root (uid 0). Re-run as a regular user.\n"
  if ( $< == 0 || $> == 0 );

print "=== COBOL PROJECT BUILD UTILITY ===\n\n";

# Define paths and file names based on the new hierarchy
my $bin_dir  = "../bin";
my $src_dir  = "./src";
my $data_dir = "../data";
my $csv_file = "$data_dir/input.csv";
my $cob_file = "$src_dir/ledger.cob";
my $app_bin  = "$bin_dir/legacy_app";

# 1. Check/Create Directories
if ( !-d $bin_dir ) {
    mkdir $bin_dir or die "[ERROR] Could not create directory $bin_dir: $!\n";
}
foreach my $dir ( $src_dir, $data_dir ) {
    die "[INFO] Directory '$dir' does not exist.\n" unless ( -d $dir );
}
print "[OK] Directory structure verified.\n";

# 2. Check Input CSV File
if ( !-e $csv_file ) {
    print "[WARNING] Input file '$csv_file' is missing!\n";
}
else {
    print "[OK] Input file '$csv_file' found.\n";
}

# 3. Check COBOL Source File
die "[ERROR] COBOL source file '$cob_file' not found!\n"
  unless ( -e $cob_file );
print "[OK] COBOL source file '$cob_file' verified.\n";

print "\n--- STARTING COMPILATION PROCESS ---\n";

# 4. Compile COBOL Program placing output in bin/app
print "[BUILD] Compiling $cob_file -> $app_bin...\n";
my $cob_result = system("cobc -x -o $app_bin $cob_file");
if ( $cob_result != 0 ) {
    die "[ERROR] COBOL compilation failed. Make sure GnuCOBOL is installed.\n";
}
print "[SUCCESS] Executable generated at '$app_bin' successfully.\n";

print "\n=== BUILD COMPLETED SUCCESSFULLY ===\n";
