# Provides a common test routine to avoid repeating the same
# code over and over again.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
#
########################################################################

# This accepts several type of tests:
#
#
# * po4a.conf test. List of accepted keys:
#   doc            (opt): Free string
#   po4a.conf      (req): path to a config file for po4a
#   options        (opt): extra parameters to pass to po4a, in addition to "--destdir tmp --verbose" that is unavoidable.

#   diff_outfile     (opt): Command to use to check that the po4a command produced the right output
#   expected_outfile (opt): Name of the file containing the expected output of the po4a command
#   expected_retcode (opt): Return value expected for po4a (0 by default). Useful to test invalid inputs.

#   expected_files (opt): array of file names that are expected after the test execution. If provided:
#                          - Any missing or unexpected file is a test failure.
#                          - The expected content of $file must be provided in _$file or $file
#                            (use _$file for pure output files that are not supposed to be read by po4a).
#                            For that, a test is added automatically unless your tests already contain a line matching '$path/$file tmp/$path/$file'.
#                            This test is 'PODIFF -I#: $path/$file tmp/$path/$file' if your file is a po/pot file, or 'diff -u $path/$file tmp/$path/$file'
#   tests          (opt): array of shell commands to run after the test; any failure is reported as a test failure
#                         Automatic substitutions in each command:
#                           PATH   -> Path to po4a binaries
#                           PODIFF -> "diff -u -I'^\"POT-Creation-Date:' -I'^\"PO-Revision-Date:'"

#   setup          (opt): array of shell commands to run before running the test
#   teardown       (opt): array of shell commands to run after running the test
#   closed_path    (opt): a shell pattern to pass to chmod to close the other directories.
#                         If provided, setup/teardown commands are generated to:
#                           - 'chmod 0' the directories marked 'closed_path'
#                           - 'chmod +r-w+x' the test directory
#                           - 'chmod +r-w' all files in the test directory
#   modes          (opt): space separated modes to apply. Valid values:
#                         - srcdir: cd tmp/$path ; po4a --srcdir  $cwd/$path     ; cd $cwd; <all tests>
#                         - dstdir: cd $path     ; po4a --destdir $cwd/tmp/$path ; cd $cwd: <all tests>
#                         - srcdstdir: po4a --srcdir $cwd/$path --destdir $cwd/tmp/$path ;  <all tests>
#                         - curdir: cp $path/* tmp/$path ; cd tmp/$path ; po4a ; cd $cwd;   <all tests but the one checking that only expected files were created>
#                         If several values are provided, the tests are run several times. By default: run all modes.
#

# * 'format' test: modern tests to the formats. This kind of tests are mostly configured through files. Accepted keys
#   - format (req): the module to use
#   - input (req) : input file name (decomposed as $basename.$ext in the following)
#   - norm (default: $basename.norm): expected normalized document (translated with inexistant language)
#   - potfile (default: $basname.pot): expected POT file
#   - pofile (default: $basname.po): PO file used as input
#   - stderr (optional -- default: $basename.stderr): expected output of the normalization.
#            If the file does not exist, the normalization is expected to not output anything
#   - trans_stderr (optional -- default: $basename.trans.stderr): expected output of the translation
#            If the file does not exist, the normalization is expected to not output anything
#   - options (optional): options to pass to the translation and normalization
#
#     if a file $basename.desc exists, any comment is used as test description while the rest is added to the options

# * 'format' tests: TODO. For now, they are normalize tests, the old way of doing this
# * 'run' test: ancient, unconverted tests

package Testhelper;

use strict;
use warnings;
use Test::More 'no_plan';
use File::Path qw(make_path remove_tree);
use Cwd qw(cwd);

use Exporter qw(import);
our @EXPORT = qw(run_all_tests);

# Set the right environment variables to normalize the outputs
$ENV{'LC_ALL'}  = "C";
$ENV{'COLUMNS'} = "80";

# Path to the tested executables. AUTOPKGTEST_TMP is set on salsa CI for Debian packages.
my $execpath = defined $ENV{AUTOPKGTEST_TMP} ? "/usr/bin" : "perl ..";

my $PODIFF =
  "-I'Copyright (C) 20.. Free Software Foundation, Inc.' -I'^# Automatically generated, 20...' -I'^\"POT-Creation-Date:' -I'^\"PO-Revision-Date:'";

sub show_files {
    my $basename = shift;
    foreach my $file ( glob("${basename}*") ) {
        if ( -s $file ) {
            diag("Produced file $file:");
            open FH, "$file" || die "Cannot open exisiting $file, I'm puzzled";
            while (<FH>) {
                diag("  $_");
            }
            diag("(end of $file)\n");
            diag("-------------------------------------------------------------");
            close(FH);
        }
    }
}

# Returns whether the details should be shown
sub system_failed {
    my ( $cmd, $doc, $expected_exit_status ) = @_;
    $expected_exit_status //= 0;
    my $exit_status = system($cmd);
    $cmd =~
      s/diff -u -I'Copyright .C. 20.. Free Software Foundation, Inc.' -I'.. Automatically generated, 20...' -I'."POT-Creation-Date:' -I'."PO-Revision-Date:'/PODIFF/g;
    if ( $exit_status == $expected_exit_status ) {
        if ( $doc ne '' ) {
            pass($doc);
            pass("  Command: $cmd");
        } else {
            pass("$cmd");
        }
        return 0;
    } else {
        $doc = 'Provided command' unless $doc ne '';
        fail( $doc . " (retcode: $exit_status)" );
        note("Expected retcode: $expected_exit_status");
        note("FAILED command: $cmd");
        return 1;
    }
}

sub teardown {
    my $ref  = shift;
    my @cmds = @{$ref};

    foreach my $cmd (@cmds) {
        if ( system("$cmd 1>&2") ) {
            diag("Error during teardown: $!");
            diag("  Command: $cmd");
        } else {
            pass("Teardown command: $cmd");
        }
    }
}

sub setup {
    my $ref  = shift;
    my @cmds = @{$ref};

    foreach my $cmd (@cmds) {
        if ( system("$cmd 1>&2") ) {
            diag("Error during setup: $!");
            diag("  Command: $cmd");
            return 0;
        } else {
            pass("Setup command: $cmd");
        }
    }
    return 1;
}

sub run_one_po4aconf {
    my ( $t, $path, $basename, $ext, $mode ) = @_;

    my %valid_options;
    map { $valid_options{$_} = 1 }
      qw(po4a.conf todo doc closed_path options setup tests teardown expected_retcode expected_files diff_outfile expected_outfile );
    map { die "Invalid test " . $t->{'doc'} . ": invalid key '$_'\n" unless exists $valid_options{$_} } ( keys %{$t} );

    my $po4aconf         = $t->{'po4a.conf'} || fail("Broken test: po4a.conf must be provided");
    my $options          = "--verbose " . ( $t->{'options'} // "" );
    my $closed_path      = $t->{'closed_path'};
    my $doc              = $t->{'doc'};
    my $expected_files   = $t->{'expected_files'} // "";
    my $expected_retcode = $t->{'expected_retcode'} // 0;

    fail("Broken test: 'tests' is not an array as expected") if exists $t->{tests} && ref $t->{tests} ne 'ARRAY';
    my ( @tests, @setup, @teardown ) = ( (), (), () );
    map { push @tests,    $_; } @{ $t->{'tests'} }    if exists $t->{'tests'};
    map { push @setup,    $_; } @{ $t->{'setup'} }    if exists $t->{'setup'};
    map { push @teardown, $_; } @{ $t->{'teardown'} } if exists $t->{'teardown'};

    fail("Broken test: path $path does not exist") unless -e $path;

    if ($closed_path) {
        push @setup,    "chmod -r-w-x " . $closed_path;    # Don't even look at the closed path
        push @teardown, "chmod +r+w+x " . $closed_path;    # Restore permissions
        push @setup,    "chmod +r+x $path";                # Look into the path of this test
        push @setup,    "chmod -w -R $path";               # But don't change any file in there
        push @teardown, "chmod +w -R $path";               # Restore permissions
    }

    my $cwd     = cwd();
    my $tmppath = "tmp/$path";
    $execpath = defined $ENV{AUTOPKGTEST_TMP} ? "/usr/bin" : "perl $cwd/..";

    my $run_from = '.';
    if ( $mode eq 'srcdir' ) {
        $tmppath .= '-src';
        $run_from = $tmppath;
        $options  = "--srcdir $cwd/$path $options";
    } elsif ( $mode eq 'dstdir' ) {
        $run_from = $path;
        $options  = "--destdir $cwd/$tmppath $options";
    } elsif ( $mode eq 'srcdstdir' ) {
        $tmppath .= '-srcdst';
        $options = "--srcdir $path --destdir $tmppath $options";
    } elsif ( $mode eq 'curdir' ) {
        $tmppath .= '-cur';
        push @setup, "cp $path/* $tmppath";
        push @setup, "chmod +w $tmppath/*";
        $run_from = $tmppath;
    } else {
        die "Malformed test: mode $mode unknown\n";
    }

    system("rm -rf $tmppath/")   && die "Cannot cleanup $tmppath/ on startup: $!";
    system("mkdir -p $tmppath/") && die "Cannot create $tmppath/: $!";
    unless ( setup( \@setup ) ) {    # Failed
        teardown( \@teardown );
        return;
    }

    my $cmd = "$execpath/po4a -f $cwd/$po4aconf $options > $cwd/$tmppath/output 2>&1";

    system("mkdir -p $tmppath/") && die "Cannot create $tmppath/: $!";

    chdir $run_from || fail "Cannot change directory to $run_from: $!";
    pass("Change directory to $run_from");
    die "Malformed test: conf file $cwd/$po4aconf does not exist from " . cwd() . " (mode:$mode)\n"
      unless -e "$cwd/$po4aconf";
    if ( system_failed( $cmd, "Executing po4a", $expected_retcode ) ) {
        chdir $cwd || fail "Cannot change directory back to $cwd: $!";
        note("Produced output:");
        open FH, "$tmppath/output" || die "Cannot open output file that I just created, I'm puzzled";
        while (<FH>) {
            note("  $_");
        }
        note("(end of command output)\n");

        teardown( \@teardown );

        #        show_files("$tmppath/");
        return;
    }
    chdir $cwd || fail "Cannot change directory back to $cwd: $!";
    pass("Change directory back to $cwd");

    my $expected_outfile = $t->{'expected_outfile'} // "$path/_output";
    unless ( $t->{'diff_outfile'} ) {
        $expected_outfile = "$path/$expected_outfile"
          if ( not -e $expected_outfile ) && ( -e "$path/$expected_outfile" );
        unless ( -e $expected_outfile ) {
            teardown( \@teardown );
            die "Malformed test $path ($doc): no expected output. Please touch $expected_outfile\n";
        }
    }
    my $diff_outfile = $t->{'diff_outfile'}
      // " sed -e 's|$cwd/||' -e 's|$tmppath/||' -e 's|$path/||' $tmppath/output | " . "diff -u $expected_outfile -";
    if ( system_failed( "$diff_outfile 2>&1 > $tmppath/diff_output", "Comparing output of po4a" ) ) {
        note("Output difference:");
        open FH, "$tmppath/diff_output" || die "Cannot open output file that I just created, I'm puzzled";
        while (<FH>) {
            chomp;
            note("  $_");
        }
        note("(end of diff)\n");
        teardown( \@teardown );
        show_files("$tmppath/");
        return;
    }

    my %expected;
    map { $expected{$_} = 1 } split / +/, $expected_files;
    if ( length $expected_files == 0 ) {
        note("Expecting no output file.");
    } else {
        note( "Expecting " . ( scalar %expected ) . " output files: $expected_files" );
    }
    $expected{'output'}      = 1;
    $expected{'diff_output'} = 1;
  FILE: foreach my $file ( glob("$tmppath/*") ) {
        $file =~ s|$tmppath/||;
        if ( not $expected{$file} ) {
            if ( ( $mode eq 'srcdir' || $mode eq 'dstdir' || $mode eq 'srcdstdir' ) ) {
                teardown( \@teardown );
                fail "Unexpected file '$file'";
            }
        } else {
            delete $expected{$file};
            next FILE if $file eq 'output' || $file eq 'diff_output';
            if ( scalar grep { m{$tmppath/$file} } @tests ) {
                note("Using the provided test to compare the content of $file");
            } elsif ( -e "$path/_$file" ) {
                push @tests, ( $file =~ 'pot?$' ? "PODIFF -I#: " : "diff -u" ) . " $path/_$file $tmppath/$file";
            } elsif ( -e "$path/$file" ) {
                push @tests, ( $file =~ 'pot?$' ? "PODIFF -I#: " : "diff -u" ) . " $path/$file $tmppath/$file";
            } else {
                teardown( \@teardown );
                fail("Broken test $path: $path/_$file should be the expected content of produced file $file");
            }
        }
    }
    foreach my $file ( keys %expected ) {
        fail "Missing file '$file'";
    }

    for my $tcmd (@tests) {

        #        print STDERR "cmd: $tcmd\n";
        $tcmd =~ s/PATH/${execpath}/g;
        $tcmd =~ s/PODIFF/diff -u $PODIFF /g;
        if ( system_failed( "$tcmd 2>&1 > $tmppath/_cmd_output", "" ) ) {
            note("Command output:");
            open FH, "$tmppath/_cmd_output" || die "Cannot open output file that I just created, I'm puzzled";
            while (<FH>) {
                chomp;
                note("| $_");
            }
            note("(end of output)\n");
            teardown( \@teardown );
            show_files("$tmppath/");
            return;
        }
        unlink("$tmppath/_cmd_output");
    }

    teardown( \@teardown );
}

sub run_one_format {
    my ( $test, $input ) = @_;

    my $doc = $test->{'doc'} // "Format testing '$input'";

    my %valid_options;
    map { $valid_options{$_} = 1 } qw(format input norm potfile pofile stderr trans_stderr doc options);
    map { die "Invalid test " . $test->{'doc'} . ": invalid key '$_'\n" unless exists $valid_options{$_} }
      ( keys %{$test} );

    die "Broken test: input file $input does not exist or not readable." unless -e $input && -r $input;

    my $format = $test->{'format'} // die "Broken test $input: no format provided\n";

    $input =~ m|^(.*)/([^/]*)\.([^/]*)$| || die "Broken test: input file '$input' is not of form PATH/BASE.EXT";
    my ( $path, $basename, $ext ) = ( $1, $2, $3 );

    my $output = $test->{'norm'} // "$path/$basename.norm";
    fail "Broken test $basename: expected normalized file '$output' does not exist" unless -e $output;
    my $potfile = $test->{'potfile'} // "$path/$basename.pot";
    fail "Broken test $basename: expected POT file '$potfile' does not exist" unless -e $potfile;
    my $pofile = $test->{'pofile'} // "$path/$basename.po";
    fail "Broken test $basename: expected PO file '$pofile' does not exist" unless -e $pofile;

    my $stderr   = $test->{'stderr'}       // "$path/$basename.stderr";          # this file is optionnal
    my $transerr = $test->{'trans_stderr'} // "$path/$basename.trans.stderr";    # this file is optionnal

    my $options = $test->{'options'} // "";
    my (@tests);

    if ( -e "$path/$basename.desc" ) {
        open FH, "<$path/$basename.desc" || die "Cannot read $path/$basename.desc: $!";
        while (<FH>) {
            chomp;
            s{#(.*)$}{} and $doc = $1;
            s{^[ \t]+}{};
            next if m{^$};
            $options .= "$_ ";
        }
    }

    system("mkdir -p tmp/$path/") && die "Cannot create tmp/$path/: $!";
    my $tmpbase = "tmp/$path/$basename";
    my $cwd     = cwd();
    $execpath = defined $ENV{AUTOPKGTEST_TMP} ? "/usr/bin" : "perl $cwd/..";

    # Normalize the document
    my $cmd =
        "${execpath}/po4a-normalize -f $format "
      . "--pot $cwd/${tmpbase}.pot --localized $cwd/${tmpbase}.norm $options $basename.$ext"
      . " > $cwd/tmp/$path/stderr 2>&1";

    chdir $path || fail "Cannot change directory to $path: $!";
    note("Change directory to $path");
    my $exit_status = system($cmd);
    chdir $cwd || fail "Cannot change directory back to $cwd: $!";
    note("Change directory back to $cwd");

    my $real_stderr = "tmp/$path/stderr";
    if ( $exit_status == 0 ) {
        pass("Normalizing $doc");
        note("  Pass: $cmd");
    } else {
        fail("Normalizing $doc: $exit_status");
        note("  FAIL: $cmd");
        note("Produced output:");
        open FH, $real_stderr || die "Cannot open output file that I just created, I'm puzzled";
        while (<FH>) {
            note("  $_");
        }
        note("(end of command output)\n");

    }

    push @tests, "diff -uN $stderr $real_stderr";
    push @tests, "PODIFF  $path/$basename.pot  $tmpbase.pot";
    push @tests, "diff -u $path/$basename.norm $tmpbase.norm";

    # Translate the document
    $cmd =
        "${execpath}/po4a-translate -f $format $options --master $path/$basename.$ext"
      . " --po $path/$basename.po --localized ${tmpbase}.trans"
      . " > $cwd/tmp/$path/trans.stderr 2>&1";

    if ( system_failed( $cmd, "" ) ) {
        note("Produced output:");
        open FH, "$cwd/tmp/$path/trans.stderr" || die "Cannot open output file that I just created, I'm puzzled";
        while (<FH>) {
            note("  $_");
        }
        note("(end of command output)\n");
    }

    push @tests, "diff -uN $transerr $cwd/tmp/$path/trans.stderr";
    push @tests, "diff -uN $path/$basename.trans  $tmpbase.trans";

    # Run all accumulated tests
    for my $tcmd (@tests) {
        $tcmd =~ s/PATH/${execpath}/g;
        $tcmd =~ s/PODIFF/diff -u $PODIFF /g;
        if ( system_failed( "$tcmd  > $tmpbase.cmd_output 2>&1", "" ) ) {
            note("Command output:");
            open FH, "$tmpbase.cmd_output" || die "Cannot open output file that I just created, I'm puzzled";
            while (<FH>) {
                chomp;
                note("| $_");
            }
            note("(end of output)\n");
            show_files("tmp/$path");
            return;
        }
        unlink("$tmpbase.cmd_output");
    }
}

sub run_one_normalize {
    my ( $test, $options, $test_directory, $basename, $ext ) = @_;

    system("mkdir -p tmp/$basename/") && die "Cannot create tmp/$basename/: $!";
    my $tmpbase = "tmp/$basename/$basename";

    unless ( -e "$test_directory/$basename.pot" ) {
        fail("Broken test: Expected outfile ${tmpbase}.pot does not exist");
        return;
    }

    ####
    # Normalize the document
    my $cmd =
        "${execpath}/po4a-normalize "
      . "--pot ${tmpbase}.pot --localized ${tmpbase}.out $options $test_directory/$basename.$ext"
      . " > ${tmpbase}.err 2>&1";
    my $name = "$basename (" . $test->{'doc'} . ")";

    my $exit_status = system($cmd);
    if ( $exit_status == 0 ) {
        pass("Normalizing $name");
        pass("  Pass: $cmd");
    } else {
        fail("Normalizing $name: $exit_status");
        note("  FAIL: $cmd");
        note("Produced output:");
        open FH, "$tmpbase.err" || die "Cannot open output file that I just created, I'm puzzled";
        while (<FH>) {
            note("  $_");
        }
        note("(end of command output)\n");

    }

    ####
    # Check that the normalize result matches the expectations
    my $fail = 0;
    my @cmds;
    push @cmds, "PODIFF -I^#: $test_directory/$basename.pot ${tmpbase}.pot";
    push @cmds, "diff -u $test_directory/$basename.out ${tmpbase}.out";
    push @cmds, "diff -u $test_directory/$basename.err ${tmpbase}.err";

    foreach my $tcmd (@cmds) {
        $tcmd =~ s/PODIFF/diff -u $PODIFF/g;
        $exit_status = system( $tcmd. " 1>&2" );
        $tcmd =~
          s/diff -u -I'Copyright .C. 20.. Free Software Foundation, Inc.' -I'.. Automatically generated, 20...' -I'."POT-Creation-Date:' -I'."PO-Revision-Date:'/PODIFF/g;
        if ( $exit_status == 0 ) {
            pass("  pass: $tcmd");
        } else {
            fail("Normalization result does not match.");
            fail("  Failed command: $tcmd");
            fail("  Files were produced with: $cmd");
            $fail++;
        }
    }
    unless ( $fail == 0 ) {
        show_files($tmpbase);
        return;
    }

    ####
    # If there's a translation, also test the translated output.
    if ( -f "$test_directory/$basename.trans.po" ) {
        $cmd =
            "${execpath}/po4a-translate $options --master $test_directory/$basename.$ext"
          . " --po $test_directory/$basename.trans.po --localized ${tmpbase}.trans.out"
          . " > ${tmpbase}.trans.err 2>&1";

        $exit_status = system($cmd);
        if ( $exit_status == 0 ) {
            pass("Translation of $name");
            pass("  Pass: $cmd");
        } else {
            fail("Translation of $name");
            fail("  FAIL: $cmd");
            show_files($tmpbase);
            return;
        }

        ####
        # Check that the translation result matches the expectations
        $fail = 0;
        @cmds = ();
        push @cmds, "diff -u $test_directory/$basename.trans.out ${tmpbase}.trans.out";
        push @cmds, "diff -u $test_directory/$basename.trans.err ${tmpbase}.trans.err";
        foreach my $tcmd (@cmds) {
            $exit_status = system( $tcmd. " 1>&2" );
            if ( $exit_status == 0 ) {
                pass("  pass: $tcmd");
            } else {
                fail("Translation result does not match.");
                fail("  FAIL: $tcmd");
                $fail++;
            }
        }
        unless ( $fail == 0 ) {
            show_files($tmpbase);
            return;
        }

    }
}

sub run_all_tests {
    my @cases = @_;

    # Change into test directory and create a temporary directory
    chdir "t" or die "Can't chdir to test directory t\n";

    remove_tree("tmp") if ( -e "tmp" );
    make_path("tmp");

  TEST: foreach my $test (@cases) {
        if ( exists $test->{'normalize'} ) {
            if ( $test->{'normalize'} =~ m|^(.*) (.*)/([^/]*)\.([^/]*)$| ) {
                my ( $options, $path, $basename, $ext ) = ( $1, $2, $3, $4 );

                $test->{'doc'} = "Normalizing $basename" unless exists $test->{'doc'};

                if ( exists $test->{'todo'} ) {
                  TODO: {
                        print STDERR "TODO: " . $test->{doc} . "\n";
                        local our $TODO = $test->{'todo'};
                        subtest $test->{'doc'} => sub { run_one_normalize( $test, $options, $path, $basename, $ext ); }
                    }
                } else {
                    subtest $test->{'doc'} => sub { run_one_normalize( $test, $options, $path, $basename, $ext ); }
                }

            } else {
                die "Invalid 'normalize' key in test definition: $test->{'doc'}\n";
            }
        } elsif ( exists $test->{'format'} ) {
            my $input = $test->{'input'} // die "Broken test: 'format' tests must declare an 'input' key'";
            $test->{'doc'} = "Format $input" unless exists $test->{'doc'};

            if ( exists $test->{'todo'} ) {
              TODO: {
                    print STDERR "TODO: " . $test->{doc} . "\n";
                    local our $TODO = $test->{'todo'};
                    subtest $test->{'doc'} => sub { run_one_format( $test, $input ); }
                }
            } else {
                subtest $test->{'doc'} => sub { run_one_format( $test, $input ); }
            }
        } elsif ( exists $test->{'po4a.conf'} ) {

            if ( $test->{'po4a.conf'} =~ m|^(.*)/([^/]*)\.([^./]*)$| ) {
                my ( $path, $basename, $ext ) = ( $1, $2, $3 );

                my @modes;
                if ( exists $test->{'modes'} ) {
                    push @modes, split( / /, $test->{'modes'} );
                    delete $test->{'modes'};
                } else {
                    push @modes, (qw(dstdir srcdir srcdstdir curdir));
                }
                map {
                    die "Malformed test: mode '$_' invalid."
                      unless $_ eq 'dstdir' || $_ eq 'srcdir' || $_ eq 'srcdstdir' || $_ eq 'curdir';
                } @modes;

                if ( exists $test->{'todo'} ) {
                  TODO: {
                        local our $TODO = $test->{'todo'};
                        foreach my $mode (@modes) {
                            subtest $test->{'doc'}
                              . " ($mode)" => sub { run_one_po4aconf( $test, $path, $basename, $ext, $mode ); };
                        }
                    }
                } else {
                    foreach my $mode (@modes) {
                        subtest $test->{'doc'}
                          . " ($mode)" => sub { run_one_po4aconf( $test, $path, $basename, $ext, $mode ); };
                    }
                }
            } else {
                fail "Test " . $test->{'doc'} . " malformed. Cannot parse the conf filename.";
            }

        } elsif ( exists $test->{'run'} ) {

            my $cmd = $test->{'run'};
            $cmd =~ s/PATH/${execpath}/;
            my $exit_status = system($cmd);
            is( $exit_status, 0, "Executing " . $test->{'doc'} . " -- Command: $cmd" );
            next TEST unless ( $exit_status == 0 );

            fail "Malformed test " . $test->{'doc'} . ": missing tests." unless scalar $test->{tests};
            for my $cmd ( @{ $test->{tests} } ) {

                #                print STDERR "cmd: $cmd\n";
                $cmd =~ s/PODIFF/diff -u $PODIFF/g;
                $exit_status = system( $cmd. ' 1>&2' );
                $cmd =~
                  s/diff -u -I'Copyright .C. 20.. Free Software Foundation, Inc.' -I'.. Automatically generated, 20...' -I'."POT-Creation-Date:' -I'."PO-Revision-Date:'/PODIFF/g;
                is( $exit_status, 0, "Test of " . $test->{'doc'} . " -- Command: $cmd" );
                next TEST unless ( $exit_status == 0 );
            }

        } else {
            fail "Test " . $test->{'doc'} . " does not have any 'po4a.conf' nor 'normalize' nor 'run' field";
        }
    }

    chdir ".." or die "Can't chdir back to root directory\n";
}

1;
