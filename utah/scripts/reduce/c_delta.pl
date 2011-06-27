#!/usr/bin/perl -w

use strict;
use Regexp::Common;
use re 'eval';

# build up the regexes programmatically to support multiple replacement options

# make sure file starts and ends with a blank 

# print stats for individual regexes

# add passes to 
#   remove digits from numbers to make them smaller
#   run indent speculatively
#   turn checksum calls into regular printfs
#   delete a complete function
#   delete an entire initializer

# to regexes, add a way to specify border characters that won't be removed

# avoid mangling identifiers

# harder
#   move a function to top, eliminate prototype
#   transform a function to return void
#   inline a function call
#   un-nest nested calls in expressions
#   move arguments and locals to global scope
#   remove level of pointer indirection
#   remove array dimension
#   remove argument from function, including all calls

# long term todo: rewrite this tool to operate on ASTs

my $INIT = "1";

my $num = "\\-?[xX0-9a-fA-F]+[UL]*";
my $field = "\\.f[0-9]+";
my $index = "\\\[(($num)|i|j|k|l)\\\]";
my $barevar = "val|vname|flag|[lgpt]_[0-9]+";
my $var1 = "([\\&\\*]*)($barevar)(($field)|($index))*";
my $var2 = "x|i|j|k|si|ui|si1|si2|ui1|ui2|vname|left|right|val|crc32_context|func_([0-9]+)|safe_([0-9]+)";
my $var = "($var1)|($var2)";
my $arith = "\\+|\\-|\\%|\\/|\\*";
my $comp = "\\<\\=|\\>\\=|\\<|\\>|\\=\\=|\\!\\=|\\=";
my $logic = "\\&\\&|\\|\\|";
my $bit = "\\||\\&|\\^|\\<\\<|\\>\\>";
my $binop = "($arith)|($comp)|($logic)|($bit)";
my $varnum = "($var)|($num)";
my $border = "[\\*\\{\\(\\[\\:\\,\\}\\)\\]\\;\\,]";
my $borderorspc = "(($border)|(\\s))";
my $type = "int|void";
my $lbl = "lbl_[0-9]+:";

#print "$field\n";
#print "$index\n";
#print "$border\n";
#print "$var1\n";
#print "$var2\n";

# these match without additional qualification
my @regexes_to_replace = (
    ["$RE{balanced}{-parens=>'()'}", ""],
    ["$RE{balanced}{-parens=>'{}'}", ""],
    ["=\\s*$RE{balanced}{-parens=>'{}'}", ""],
    ["($type)\\s+($varnum)\\s+$RE{balanced}{-parens=>'()'}\\s+$RE{balanced}{-parens=>'{}'}", ""],
    ["\\:\\s*[0-9]+\\s*;", ";"],
    ["\\;", ""],
    ["\\^\\=", "="],
    ["\\|\\=", "="],
    ["\\&\\=", "="],
    ["\\+\\=", "="],
    ["\\-\\=", "="],
    ["\\*\\=", "="],
    ["\\/\\=", "="],
    ["\\%\\=", "="],
    ["\\<\\<\\=", "="],
    ["\\>\\>\\=", "="],
    ["\\+", ""],
    ["\\-", ""],
    ["\\!", ""],
    ["\\~", ""],
    ['"(.*?)"', ""],
    ['"(.*?)",', ""],
    );

# these match when preceded and followed by $borderorspc
my @delimited_regexes_to_replace = (
    ["($type)\\s+($var),", ""],
    ["($lbl)\\s*:", ""],
    ["goto\\s+($lbl);", ""],
    ["const", ""],
    ["volatile", ""],
    ["char", ""],
    ["char", "int"],
    ["short", ""],
    ["short", "int"],
    ["long", ""],
    ["long", "int"],
    ["signed", ""],
    ["signed", "int"],
    ["unsigned", ""],
    ["unsigned", "int"],
    ["else", ""],
    ["static", ""],
    ["extern", ""],
    ["continue", ""], 
    ["return", ""],
    ["int argc, char \\*argv\\[\\]", "void"],
    ["int.*?;", ""],
    ["for", ""],
    ["if\\s+\\(.*?\\)", ""],
    ["struct.*?;", ""],
    ["if", ""],
    ["break", ""], 
    ["inline", ""], 
    ["printf", ""],
    ["transparent_crc", ""],
    ["print_hash_value", ""],
    ["platform_main_begin", ""],
    ["platform_main_end", ""],
    ["crc32_gentab", ""],
    );

my @function_prefixes = (
    "safe_",
    "func_",
    "sizeof",
    "transparent_crc",
    "print_hash_value",
    "platform_main_begin",
    "platform_main_end",
    "crc32_gentab",
    "if",
    "for",
    );

foreach my $f (@function_prefixes) {
    push @delimited_regexes_to_replace, ["$f(.*?)$RE{balanced}{-parens=>'()'},", "0"];
    push @delimited_regexes_to_replace, ["$f(.*?)$RE{balanced}{-parens=>'()'},", ""];
    push @delimited_regexes_to_replace, ["$f(.*?)$RE{balanced}{-parens=>'()'}", "0"];
    push @delimited_regexes_to_replace, ["$f(.*?)$RE{balanced}{-parens=>'()'}", ""];
}

my @subexprs = (
    "($varnum)(\\s*)($binop)(\\s*)($varnum)",
    "($varnum)(\\s*)($binop)",
    "($binop)(\\s*)($varnum)",
    "($barevar)",
    "($varnum)",
    "($varnum)(\\s*\\?\\s*)($varnum)(\\s*\\:\\s*)($varnum)",
    );

foreach my $x (@subexprs) {
    push @delimited_regexes_to_replace, ["$x", "0"];
    push @delimited_regexes_to_replace, ["$x", "1"];
    push @delimited_regexes_to_replace, ["$x", ""];
    push @delimited_regexes_to_replace, ["$x,", ""];
}

my $prog;

sub find_match ($$$) {
    (my $p2, my $s1, my $s2) = @_;
    my $count = 1;
    die if (!(defined($p2) && defined($s1) && defined($s2)));
    while ($count > 0) {
	return -1 if ($p2 >= (length ($prog)-1));
	my $s = substr($prog, $p2, 1);
	if (!defined($s)) {
	    my $l = length ($prog);
	    print "$p2 $l\n";
	    die;
	}
	$count++ if ($s eq $s1);
	$count-- if ($s eq $s2);
	$p2++;
    }
    return $p2-1;
}

# these are set at startup time and never change
my $cfile;
my $test;

sub read_file () {
    open INF, "<$cfile" or die;
    $prog = "";
    while (my $line = <INF>) {
	$prog .= $line;
    }
    close INF;
}

sub write_file () {
    open OUTF, ">$cfile" or die;
    print OUTF $prog;
    close OUTF;
}

sub runit ($) {
    (my $cmd) = @_;
    if ((system "$cmd") != 0) {
	return -1;
    }   
    return ($? >> 8);
}

sub run_test () {
    my $res = runit "./$test";
    return ($res == 0);
}

my %cache = ();
my $cache_hits = 0;
my $good_cnt;
my $bad_cnt;
my $pass_num = 0;
my $pos;
my %method_worked = ();
my %method_failed = ();
my $old_size = 1000000000;
    
sub delta_test ($) {
    (my $method) = @_;
    my $len = length ($prog);
    print "[$pass_num $method ($pos / $len) s:$good_cnt f:$bad_cnt] ";

    # my $result = $cache{$prog};
    my $result;

    my $hit = 0;

    if (defined($result)) {
	$cache_hits++;
	print "(hit) ";
	$hit = 1;
    } else {
	write_file ();
	$result = run_test ();
	$cache{$prog} = $result;
	$hit = 0;
    }
    
    if ($result) {
	print "success\n";
	die if ($hit);
	system "cp $cfile $cfile.bak";
	$good_cnt++;
	$method_worked{$method}++;
	my $size = length ($prog);
	die if ($size > $old_size);
	if ($size < $old_size) {
	    %cache = ();
	}
	$old_size = $size;
	return 1;
    } else {
	print "failure\n";
	if (!$hit) {
	    system "cp $cfile.bak $cfile";
	}
	read_file ();    
	$bad_cnt++;
	$method_failed{$method}++;
	return 0;
    }
}

sub delta_pass ($) {
    (my $method) = @_;
    
    $pos = 0;
    $good_cnt = 0;
    $bad_cnt = 0;

    while (1) {
	return ($good_cnt > 0) if ($pos >= length ($prog));
	my $worked = 0;

	if ($method eq "replace_regex") {
	    foreach my $l (@regexes_to_replace) {
		my $str = @{$l}[0];
		my $repl = @{$l}[1];
		my $first = substr($prog, 0, $pos);
		my $rest = substr($prog, $pos);
		if ($rest =~ s/(^$str)/$repl/) {
		    print "replacing '$1' with '$repl' at $pos : ";
		    $prog = $first.$rest;
		    $worked |= delta_test ($method);
		}
	    }
	    foreach my $l (@delimited_regexes_to_replace) {
		my $str = @{$l}[0];
		my $repl = @{$l}[1];
		my $first = substr($prog, 0, $pos);
		my $rest = substr($prog, $pos);
		
		# avoid infinite loops!
		next if ($repl eq "0" && $rest =~ /($borderorspc)0$borderorspc/);
		next if ($repl eq "1" && $rest =~ /($borderorspc)0$borderorspc/);

		if ($rest =~ s/^(?<delim1>$borderorspc)(?<str>$str)(?<delim2>$borderorspc)/$+{delim1}$repl$+{delim2}/) {
		    print "delimited replacing '$+{str}' with '$repl' at $pos : ";
		    $prog = $first.$rest;
		    $worked |= delta_test ($method);
		}
	    }
	} elsif ($method eq "del_blanks_all") {
	    if ($prog =~ s/\s{2,}/ /g) {
		$worked |= delta_test ($method);
	    }
	    return 0;
	} elsif ($method eq "indent") {
	    write_file();
	    system "indent $cfile";
	    read_file();
	    $worked |= delta_test ($method);
	    return 0;
	} elsif ($method eq "del_blanks") {
	    my $rest = substr($prog, $pos);
	    if ($rest =~ /^(\s{2,})/) {
		my $len = length ($1);
		substr ($prog, $pos, $len) =  " ";
		$worked |= delta_test ($method);
	    }
	} elsif ($method eq "parens_exclusive") {
	    if (substr($prog, $pos, 1) eq "(") {
		my $p2 = find_match ($pos+1,"(",")");
		if ($p2 != -1) {
		    die if (substr($prog, $pos, 1) ne "(");
		    die if (substr($prog, $p2, 1) ne ")");
		    substr ($prog, $p2, 1) = "";
		    substr ($prog, $pos, 1) = "";
		    print "deleting at $pos--$p2 : ";
		    $worked |= delta_test ($method);
		}
	    }
	} elsif ($method eq "brackets_exclusive") {
	    if (substr($prog, $pos, 1) eq "{") {
		my $p2 = find_match ($pos+1,"{","}");
		if ($p2 != -1) {
		    die if (substr($prog, $pos, 1) ne "{");
		    die if (substr($prog, $p2, 1) ne "}");
		    substr ($prog, $p2, 1) = "";
		    substr ($prog, $pos, 1) = "";
		    print "deleting at $pos--$p2 : ";
		    $worked |= delta_test ($method);
		}
	    }
	} else {
	    die "unknown reduction method";
	}

	if (!$worked) {
	    $pos++;
	}
    }
}

# invariant: test always succeeds for $cfile.bak

my %all_methods = (

    "del_blanks_all" => 0,
    "del_blanks" => 1,
    "brackets_exclusive" => 2,
    "parens_exclusive" => 3,
    "replace_regex" => 4,
    "indent" => 5,

    );
 
#################### main #####################

sub usage() {
    print "usage: c_delta.pl test_script.sh file.c [method [method ...]]\n";
    print "available methods are --all or:\n";
    foreach my $method (keys %all_methods) {
	print "  --$method\n";
    }
    die;
}

$test = shift @ARGV;
usage if (!defined($test));
if (!(-x $test)) {
    print "test script '$test' not found, or not executable\n";
    usage();
}

$cfile = shift @ARGV;
usage if (!defined($cfile));
if (!(-e $cfile)) {
    print "'$cfile' not found\n";
    usage();
}

my %methods = ();
usage if (!defined(@ARGV));
foreach my $arg (@ARGV) {
    if ($arg eq "--all") {
	foreach my $method (keys %all_methods) {
	    $methods{$method} = 1;
	}
    } else {
	my $found = 0;
	foreach my $method (keys %all_methods) {
	    if ($arg eq "--$method") {
		$methods{$method} = 1;
		$found = 1;
		last;
	    }
	}
	if (!$found) {
	    print "unknown method '$arg'\n";
	    usage();
	}
    }
}

print "making sure test succeeds on initial input...\n";
my $res = run_test ();
if (!$res) {
    die "test fails!";
}

system "cp $cfile $cfile.orig";
system "cp $cfile $cfile.bak";

sub bymethod {
    return $all_methods{$a} <=> $all_methods{$b};
}

# iterate to global fixpoint

read_file ();    

while (1) {
    my $success = 0;
    foreach my $method (sort bymethod keys %methods) {
	$success |= delta_pass ($method);
    }
    $pass_num++;
    last if (!$success);
}

print "\n";
print "statistics:\n";
foreach my $method (sort keys %methods) {
    my $w = $method_worked{$method};
    $w=0 unless defined($w);
    my $f = $method_failed{$method};
    $f=0 unless defined($f);
    print "  method $method worked $w times and failed $f times\n";
}
print "there were $cache_hits cache hits\n";
