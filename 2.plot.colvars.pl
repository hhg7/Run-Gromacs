#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use autodie ':default';
use Cwd 'getcwd';
use Util 'execute';
use Matplotlib::Simple 'plot';
use Getopt::ArgParse;
use Term::ANSIColor;
use latex qw(write_2d_array_to_tex_tabular write_latex_figure write_latex_table_input);

my $parser = Getopt::ArgParse->new_parser(
	prog        => 'Plot output from Gromacs\' colvars module',
	description => 'Make a plot using Matplotlib::Simple',
	epilog      => 'perl ' . __FILE__ . '',
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
	suptitle          => 'Protein1 vs Protein3 Colvars'
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
