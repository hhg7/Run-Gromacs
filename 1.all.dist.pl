#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use warnings::unused;
use autodie ':default';
use Util 'execute';
use List::Util 'max';
use File::Temp 'tempfile';
use Matplotlib::Simple 'plot';
use Cwd 'getcwd';
use latex qw(write_2d_array_to_tex_tabular write_latex_figure);

my $gmx = '/home/con/prog/gromacs-2025.3/build/bin/gmx';
die "$gmx doesn't exist or isn't executable" unless -f -x $gmx;
my $ndx_file = 'npt.chains.ndx';
die "$ndx_file isn't readable or isn't a file" unless -f -r $ndx_file;
my $ndx_str = execute("$gmx check -n $ndx_file", 'stdout');
my @ndx = split /\n/, $ndx_str;
my @header = split /\h+/, $ndx[2];
shift @header;
splice @ndx, 0, 3; # remove top lines, not useful
my @group;
foreach my $line (@ndx) {
	$line =~ s/^\h+\d+\h+//;
	my @line = split /\h+/, $line;
	if (scalar @header == 0) {
		@header = @line;
		next;
	}
	my %line;
	@line{@header} = @line;
	next if $line{'Group'} =~ m/(?:Water|SOL|non\-Protein|System)/;
	push @group, $line{'Group'};
}
my $dir = 'distance';
mkdir $dir  unless -d $dir;
mkdir 'svg' unless -d 'svg';
my ( $fh, $tmp_filename ) = tempfile( DIR => '/tmp', SUFFIX => '.py', UNLINK => 0 );
close $fh;
my @output_images;
foreach my $g1 (@group) {
	my (%data, %plot_options, %max_x);
	foreach my $g2 (grep {$_ ne $g1} @group) {
=gmx distance
 -oav    [<.xvg>]           (distave.xvg)    (Opt.)
           Average distances as function of time
 -oall   [<.xvg>]           (dist.xvg)       (Opt.)
           All distances as function of time
 -oxyz   [<.xvg>]           (distxyz.xvg)    (Opt.)
           Distance components as function of time
 -oh     [<.xvg>]           (disthist.xvg)   (Opt.)
           Histogram of the distances
 -oallstat [<.xvg>]         (diststat.xvg)   (Opt.)
           Statistics for individual distances
=cut
		my $stem = "$g1.$g2";
		$stem =~ s/[~!@#\$\%^&*\(\)\-=\{\}\[\]\,\<\>!]+/_/g;
		$stem = "$dir/$stem";
		execute( "$gmx distance -f md.xtc -s md.tpr -n $ndx_file -oav $stem.oav.xvg -oall $stem.oall.xvg -oxyz $stem.oxyz.xvg -oh $stem.oh.xvg -oallstat $stem.oallstat.xvg -select 'com of group \"$g1\" plus com of group \"$g2\"'" );
		my @files = ("$stem.oav.xvg", "$stem.oall.xvg", "$stem.oxyz.xvg", "$stem.oh.xvg", "$stem.oallstat.xvg");
		my @missing_files = grep {not -s $_} @files;
		if (scalar @missing_files > 0) {
			p @missing_files;
			die "$g1 vs $g2: the above files are missing.";
		}
#		my %files = map {$_ => -s $_} @files;
#		say "$g1 vs $g2, and output files and sizes:";
#		p %files;
		foreach my $file (grep {$_ !~ m/oallstat\.xvg$/} @files) {
			my (@x, @y, $type);
			if ($file =~ m/([a-z]+)\.xvg$/) {
				$type = $1;
			} else {
				die "$g1 vs $g2: $file failed regex.";
			}
			open my $fh, '<', $file;
			while (<$fh>) {
				next if /^#/;
				chomp;
				if (/^@\h+([xy])axis\h+label\h+"([^"]+)/) {
					$plot_options{$type}{"$1axis"} = $2;
				} elsif (/^@\h+title\h+"([^"]+)/) {
					$plot_options{$type}{title} = $1;
				}
				next if /^@/;
				my @line = split;
				push @x, $line[0];
				push @y, $line[1];
			}
			close $fh;
			if (defined $max_x{$type}) {
				$max_x{$type} = max($max_x{$type}, $x[-1]);
			} else {
				$max_x{$type} = $x[-1];
			}
			@{ $data{$type}{$g2}[0] } = @x;
			@{ $data{$type}{$g2}[1] } = @y;
		}
	}
	my @plots;
	foreach my $type (sort keys %data) {
		push @plots, {
			data              => $data{$type},
			'plot.type'       => 'plot',
			title             => "$type $plot_options{$type}{title}",
			set_xlim          => "0, $max_x{$type}",
			xlabel            => $plot_options{$type}{xaxis},
			ylabel            => $plot_options{$type}{yaxis}
		};
	}
	my $output_image_filename = "svg/$g1.svg";
	plot({
		execute				=> 0,
		'input.file'		=> $tmp_filename,
		plots					=> \@plots,
		'output.filename' => $output_image_filename,
		suptitle				=> $g1,
		nrows					=> 2,
		ncols					=> 2,
		set_figwidth      => 6.4*3,
		set_figheight		=> 4.8*3
	});
	push @output_images, $output_image_filename;
}
execute("python3 $tmp_filename");

open my $tex, '>', 'distances.tex';
say $tex '%written by ' . getcwd() . '/' . __FILE__;
say $tex '\pdfsuppresswarningpagegroup=1
\documentclass{article}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{placeins, svg, subcaption, cmbright}
\usepackage[margin=0.5in]{geometry}
\title{Distance Report}
\author{David Condon}
\usepackage[colorlinks=true,urlcolor=blue,linkcolor=red]{hyperref}
\begin{document}
\maketitle
\listoffigures';
while (my ($g, $group) = each @group) {
	my $sxn = $group;
	$sxn =~ s/[!@#\$\%\^\&\*\(\)\-\=\{\}\[\]\;\'\<\>\/_]+/\\_/g; # get rid of annoying chars
	say $tex '\section{' . "$sxn}";
#	say $tex '\label{' .   "$sxn}";
	write_latex_figure({
		alignment    => '\centering',
		'image.file' => $output_images[$g],
		caption      => $sxn,
		label        => "fig:$group",
		fh           => $tex,
		width        => '\textwidth'
	});
}
say $tex '\end{document}';
close $tex;
my $stem = 'distances';
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --draftmode --halt-on-error -shell-escape $stem.tex");
execute("pdflatex --halt-on-error -shell-escape $stem.tex");
foreach my $suffix (grep {-f "$stem.$_"} ('aux', 'lof', 'log', 'out', 'toc')) {
	unlink "distances.$suffix";
}
