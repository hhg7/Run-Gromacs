#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use warnings::unused;
use autodie ':default';
use Cwd 'getcwd';
use Capture::Tiny 'capture';
use DDP {output => 'STDOUT', array_max => 10, show_memsize => 1};
use Devel::Confess 'color';
use Matplotlib::Simple 'plot';
use Getopt::ArgParse;
use Term::ANSIColor;
use latex qw(write_2d_array_to_tex_tabular write_latex_figure write_latex_table_input);

sub execute ($cmd, $return = 'exit', $die = 1) {
	if ($return !~ m/^(exit|stdout|stderr|all)$/) {
		die "you gave \$return = \"$return\", while this subroutine only accepts ^(exit|stdout|stderr)\$";
	}
	my ($stdout, $stderr, $exit) = capture {
		system( $cmd )
	};
	if (($die == 1) && ($exit != 0)) {
		say STDERR "exit = $exit";
		say STDERR "STDOUT = $stdout";
		say STDERR "STDERR = $stderr";
		die "$cmd\n failed";
	}
	if ($return eq 'exit') {
		return $exit
	} elsif ($return eq 'stderr') {
		chomp $stderr;
		return $stderr
	} elsif ($return eq 'stdout') {
		chomp $stdout;
		return $stdout
	} elsif ($return eq 'all') {
		chomp $stdout;
		chomp $stderr;
		return {
			exit   => $exit, 
			stdout => $stdout, 
			stderr => $stderr
		}
	} else {
		die "$return broke pigeonholes"
	}
	return $stdout
}
my $parser = Getopt::ArgParse->new_parser(
	prog        => 'Plot output from Gromacs\' colvars module',
	description => 'Make plots of colvars output',
	epilog      => 'perl ' . __FILE__ . ' -t 2PUY -l 2puy.colvars',
);

$parser->add_args(
#   [ '--colvar-input-file', '-c', type => 'Scalar', required => 0],
	[
		'--latex-output-stem',
		'-l',
		required => 1,
		help => 'LaTeX output file, e.g. "2PUY.colvars"',
		type => 'Scalar'
	],
   [ '--title', '-t',  type => 'Scalar', required => 1, help => 'Title (scalar/string)'],
);
my $args = $parser->parse_args( @ARGV );
my (@plots, @header, $dt, @time, %data, $dir, $config_file);
open my $md, '<', 'md.log';
my @md = <$md>;
close $md;
chomp @md;
foreach my $line (@md) {
	if ($line =~ m/^\h+dt\h+=\h+(\d+)\.(\d+)/) {
		$dt = "$1.$2";
		next;
	}
	if ($line =~ m/^Working dir:\h+(.+)$/) {
		$dir = $1;
		next;
	}
}
my $str = join ('я', @md);
if ($str =~ m/colvars:я
\h+active	  \h+=\h+trueя
\h+configfile \h+=\h+([^я]+)
       /x) {
	$config_file = $1;
} else {
	say $str;
	die 'Could not get colvars input file from md.log';
}
$config_file =~ s/^$dir\///;
open my $fh, '<', $config_file;
my @config = <$fh>;
close $fh;
open $fh, '<', 'md.colvars.traj';
while (<$fh>) {
	chomp;
	if ($. == 1) {
		$_ =~ s/^#?\h+//;
		@header = split /\h+/, $_;
		next;
	}
	next if /^#/;
	my @line = split;
	next if scalar @line != scalar @header; # incomplete lines can occur at the end
	push @time, $dt * $line[0];
	foreach my $col (1..$#header) {
		push @{ $data{$header[$col]} }, $line[$col];
	}
}
close $fh;
shift @header; # remove "step" which isn't used
foreach my $col (@header) {
	push @plots, {
		data        => {
			$col => [
				[@time],
				[@{ $data{$col} }]
			]
		},
	  'show.legend'     => 0,
		title       => $col,
		xlabel      => 'Time (ps)',
		'plot.type' => 'plot'
	};
}
mkdir 'svg' unless -d 'svg';
my $stem = $args->latex_output_stem;
open my $tex, '>', "$stem.tex";
say $tex '%written by ' . getcwd() . '/' . __FILE__;
say $tex '\pdfsuppresswarningpagegroup=1
\documentclass{article}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{placeins, svg, subcaption, cmbright, minted}
\usepackage[margin=0.5in]{geometry}
\title{Simulation Report}
\author{David Condon}
\usepackage[colorlinks=true,urlcolor=blue,linkcolor=red]{hyperref}
\begin{document}
\maketitle
\tableofcontents';
say $tex '\section{Colvars input}';
say $tex '\begin{minted}{text}';
say $tex join ('', @config);
say $tex '\end{minted}';
plot({
	'output.filename' => 'colvars.svg',
	plots             => \@plots,
	ncols             => scalar @header,
	set_figwidth      => 12,
	suptitle          => $args->title . ' Colvars'
});
say $tex '\section{Plot of Output}';
write_latex_figure({
	alignment    => '\centering',
	'image.file' => 'colvars.svg',
	caption      => 'Colvars Output',
	label        => 'fig:colvars',
	fh           => $tex,
	width        => '\textwidth'
});
say $tex '\end{document}';
close $tex;
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --halt-on-error -shell-escape $stem.tex");
foreach my $suffix (grep {-f "$stem.$_"} ('aux', 'lof', 'log', 'out', 'toc')) {
	unlink "$stem.$suffix";
}
say 'Wrote ' . colored(['black on_white'], "$stem.pdf");
