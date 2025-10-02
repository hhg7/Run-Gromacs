#!/usr/bin/env perl

use 5.042;
no source::encoding;
#use re 'debugcolor';
#use File::Temp 'tempfile';
use warnings FATAL => 'all';
use warnings::unused;
use Cwd 'getcwd';
use List::MoreUtils 'first_index';
use autodie ':default';
use Util 'execute';
use latex qw(write_2d_array_to_tex_tabular write_latex_figure write_latex_table_input);
use Matplotlib::Simple 'plot';
use Term::ANSIColor;

=mission statement

This script plots output from Gromacs output files and puts all output into a LaTeX file

=cut

my @log_files = ('em.log', 'nvt.log', 'npt.log', 'md.log');
#my @xvg_files = ('gyrate.xvg', 'rmsd_xray.xvg', 'mindist.xvg');
#my @missing_files = grep {not -f $_} (@log_files, @xvg_files);
#if (scalar @missing_files > 0) {
#	p @missing_files;
#	die 'the above files are not present or are not files.';
#}
my $tex_filename = 'simulation.report.tex';
open my $tex, '>', $tex_filename;
say $tex '%written by ' . getcwd() . '/' . __FILE__;
say $tex '\pdfsuppresswarningpagegroup=1
\documentclass{article}
\renewcommand{\familydefault}{\sfdefault}
\usepackage{placeins, svg, subcaption, cmbright}
\usepackage[margin=0.5in]{geometry}
\title{Simulation Report}
\author{David Condon}
\usepackage[colorlinks=true,urlcolor=blue,linkcolor=red]{hyperref}
\begin{document}
\maketitle
\tableofcontents';
#my ($tmp, $tmp_filename) = tempfile(DIR => '/tmp', SUFFIX => '.py', UNLINK => 0);
#close $tmp;
my %log2title = (
	'npt.log' => 'Number of particles, Pressure, and Temperature are held constant',
	'nvt.log' => 'NVT ensemble (constant Number of particles, Volume, and Temperature)',
	'em.log'  => 'Energy Minimization',
	'md.log'  => 'Molecular Dynamics'
);
foreach my $log (grep {-f $_} @log_files) {
	open my $fh, '<', $log;
	my @log = <$fh>;
	close $fh;
	splice @log, 0, first_index { /^GROMACS:\h+/ } @log;
	my %data;
	@log = grep {$_ !~ m/^\++\h+PLEASE .+\++/} @log;
	@log = grep {$_ !~ m/^DOI:\h/} @log;
	@log = grep {$_ !~ m/^\-+.+Thank You\h\-+/} @log;
	my $performance_i = first_index { /^Performance:\h+\d+/ } @log;
	if (
			($performance_i > 0)
			&&
			($log[$performance_i] =~ m/^Performance:\h+(\d+)\.(\d+)\h+(\d+)\.(\d+)/)
		) {
		say $log[$performance_i];
		$data{$log}{'ns/day'}  = "$1.$2";
		$data{$log}{'hour/ns'} = "$3.$4";
	}
	my $last_i = first_index { /^\h+Statistics over \d+ steps using \d+ frames/ } @log;
	if ($last_i > 0) {
		splice @log, $last_i - $#log;
	}
	foreach my $line (grep {/^There are: \d+ Atoms$/} @log) {
		if ($line =~ m/(\d+)/) {
			$data{$log}{'Atom Count'} = $1;
		} else {
			die "$line failed regex.";
		}
	}
	chomp @log;
	foreach my $line (grep {$_ =~ m/^.+:\h+\H+/} @log) {
		my @line = split /:\h+/, $line;
		$data{$log}{$line[0]} = $line[1];
	}
#	p @log, array_max => scalar @log;
	foreach my $writing_index (reverse grep { $log[$_] =~ m/^Writing checkpoint/} 0..$#log) {
		splice @log, $writing_index, 3;
	}
	my $input_param_i = first_index {$_ eq 'Input Parameters:'} @log;
	my $qm_opts_i     = first_index {$_ eq 'qm-opts:'}          @log;
	foreach my $i ($input_param_i..$qm_opts_i) {
		$log[$i] =~ s/^\h+//;
		my @line = split /\h+=\h+/, $log[$i];
		$data{$log}{$line[0]} = $line[1];
	}
	p %data;
	my @time_indices = grep {
									$log[$_-1] =~ m/^\h+Step\h+Time$/
								&&
									$log[$_] =~ m/^\h+\d+\h+[\d\.]+$/
								&&
									$log[$_+1] eq ''
								&&
									$log[$_+2] eq '   Energies (kJ/mol)'
								} 0..$#log;
	if (scalar @time_indices == 0) {
		die "Couldn't get times for $log";
	}
	my (@time,%d,@energies,@table,@plot);
	foreach my $time_index (@time_indices) {
		if ($log[$time_index] =~ m/(\d+)\.(\d+)$/) {
			push @time, "$1.$2";
		} else {
			die "$log[$time_index] failed regex.";
		}
	}
	my $reading_energies = 'false';
	foreach (@log) {
		if ($_ eq '   Energies (kJ/mol)') {
			$reading_energies = 'true';
			next;
		}
		if ($_ eq '') {
			$reading_energies = 'false';
			next;
		}
		next unless $reading_energies eq 'true';
		if (/^\h+[A-Z]/) {
			while ($_ =~ m/(.{1,15})/g) {
				my $e = $1;
				$e =~ s/^\h+//;
				push @energies, $e;
			}
			next;
		}
		if ((/^\h+\-?\d/) && (scalar @energies > 0)) {
			$_ =~ s/^\h+//;
			my @line = split /\s+/, $_;
			if (scalar @line != scalar @energies) {
				p @energies;
				p @line;
				die "$log line $. has " . scalar @line . ' energies, but should have ' . scalar @energies . "\n";
			}
			foreach my $energy (@energies) {
				push @{ $d{$energy} }, shift @line;
			}
			undef @energies;
		}
	}
	foreach my $energy (sort keys %d) {
		my $ylab = '(kJ/mol)';
		$ylab = 'bar' if $energy =~ m/^Pres/;
		$ylab = 'K'   if $energy eq 'Temperature';
		$ylab = 'Å'   if $energy =~ m/RMSD/i;
		push @plot, {
			data => {
				$energy => [
					[     @time       ],
					[@{ $d{$energy} } ]
				]
			},
			'plot.type' => 'plot',
			'set.options' => { # set options overrides global settings
				$energy => 'color="red", linewidth=2',
			},
			'show.legend' => 0,
			title         => $energy,
			xlabel        => 'Time (ps)',
			ylabel        => $ylab
		};
	}
	my $stem = $log;
	$stem =~ s/\.log$//;
	my $output_image_file = "$stem.svg";
	say $tex '\section{' . uc "$stem}";
	plot({
#		'input.file'      => $tmp_filename,
#		execute           => 0,
		'output.filename' => $output_image_file,
		plots             => \@plot,
		ncols             => 4,
		nrows             => 5,
		set_figwidth      => 15,
		set_figheight     => 12,
		suptitle          => $log2title{$log},
	});
	write_latex_figure({
		alignment    => '\centering',
		'image.file' => $output_image_file,
		caption      => $log2title{$log},
		label        => "fig:$stem",
		fh           => $tex,
		width        => '\textwidth'
	});
	foreach my $key (grep {defined $data{$log}{$_}} ('Atom Count', 'coulombtype', 'GROMACS version', 'hour/ns', 'integrator', 'ns/day', 'System total charge')) {
		push @table, [$key, $data{$log}{$key}];
	}
	write_2d_array_to_tex_tabular({
		data           => \@table,
		tex_filename   => "$stem.tex",
		header         => ['Metric', 'Value'],
	});
	write_latex_table_input({
		alignment    => '\centering',
		fh				=> $tex,
		'tex.file'	=> "$stem.tex",
		caption		=> "$log2title{$log}",
		label			=> $log,
		size			=> '\tiny'
	});
}
my (%plot_data, %gy);
if (-f 'gyrate.xvg') {
	my @gy_header = ('time', 'Gyration Radius of Molecule', 'Radius of gyration (x)', 'Radius of gyration (y)', 'Radius of gyration (z)');
	open my $fh, '<', 'gyrate.xvg';
	while (<$fh>) {
		chomp;
		my @line = split;
		foreach my $col (@gy_header) {
			push @{ $gy{$col} }, shift @line;
		}
	}
	close $fh;
	foreach my $key (grep {$_ ne 'time'} @gy_header) {
		@{ $plot_data{$key}[0] } = @{ $gy{'time'} };
		@{ $plot_data{$key}[1] } = @{ $gy{$key}   };
	}
	plot({
	#	execute           => 0,
	#	'input.file'      => $tmp_filename,
		data              => \%plot_data,
		'output.filename' => 'gyrate.svg',
		'plot.type'       => 'plot',
		set_figwidth      => 12,
		title             => 'Gyration',
		xlabel            => 'Time (ps)',
		ylabel            => 'Radius (nm)',
		xlim              => "0, $gy{'time'}[-1]" # avoid whitespace on right and left sides
	});
	write_latex_figure({
		alignment    => '\centering',
		'image.file' => 'gyrate.svg',
		caption      => 'Radii of gyration',
		label        => "fig:gyrate",
		fh           => $tex,
		width        => '\textwidth'
	});
}
undef %plot_data;
if (-f 'mindist.xvg') {
	my (@col, @time, %prop);
	open my $fh, '<', 'mindist.xvg';
	while (<$fh>) {
		next if /^#/;
		if (/^@\h+(title|subtitle)\h+"(.+)"/) {
			$prop{$1} = $2;
			next;
		}
		if (/^@\h+s(\d+)\h+legend\h+"(.+)"/) {
			$col[$1] = $2;
			next;
		}
		next unless $_ =~ m/^\h+\d+/;
		if (scalar @col == 0) {
			die "no keys were defined, and I'm likely seeing data at line $. of mindist.xvg";
		}
		chomp;
		my @line = split;
		push @time, shift @line;
		foreach my $col (@col) {
			push @{ $plot_data{$col}[0] }, $time[-1];
			push @{ $plot_data{$col}[1] }, shift @line;
		}
	}
	close $fh;
	plot({
		data              => \%plot_data,
	#	execute           => 0,
	#	'input.file'      => $tmp_filename,
		'output.filename' => 'mindist.svg',
		'plot.type'       => 'plot',
		set_figwidth      => 12,
		suptitle          => $prop{title},
		title             => $prop{subtitle},
		xlabel            => 'Time (ps)',
		xlim              => "0, $time[-1]", # avoid whitespace on right and left sides
		ylabel            => 'Radius (nm)',
		'set.options'     => {
			'box1' => 'marker = "|"',
			'box2' => 'linestyle = "dashed"',
			'box3' => 'linestyle = "dashdot"',
		}
	});
	write_latex_figure({
		alignment    => '\centering',
		'image.file' => 'mindist.svg',
		caption      => 'Periodic Image Distances',
		label        => 'fig:mindist',
		fh           => $tex,
		width        => '\textwidth'
	});
}
if (-f 'rmsd_xray.xvg') {
	open my $fh, '<', 'rmsd_xray.xvg';
	my (@time, @rmsd);
	while (<$fh>) {
		chomp;
		my @line = split;
		push @time, $line[0];
		push @rmsd, $line[1];
	}
	close $fh;
	plot({
		data => {
			RMSD => [
				[@time],
				[@rmsd]
			]
		},
	#	execute           => 1,
	#	'input.file'      => $tmp_filename,
		'output.filename' => 'rmsd_xray.svg',
		'plot.type'       => 'plot',
		set_figwidth      => 12,
		'show.legend'     => 0,
		title             => 'RMSD with starting crystal structure',
		xlabel            => 'Time (ps)',
		xlim              => "0, $time[-1]",
		ylabel            => 'RMSD (Å)'
	});
	write_latex_figure({
		alignment    => '\centering',
		'image.file' => 'rmsd_xray.svg',
		caption      => 'RMSD with Starting Structure',
		label        => 'fig:rmsd_xray',
		fh           => $tex,
		width        => '\textwidth'
	});
}
say $tex '\end{document}';
my $stem = $tex_filename;
$stem =~ s/\.tex$//;
execute("pdflatex --draftmode --halt-on-error -shell-escape $tex_filename");
execute("pdflatex --draftmode --halt-on-error -shell-escape $tex_filename");
execute("pdflatex --draftmode --halt-on-error -shell-escape $tex_filename");
execute("pdflatex --halt-on-error -shell-escape $tex_filename");
foreach my $suffix (grep {-f "$stem.$_"} ('aux', 'lof', 'log', 'out', 'toc')) {
	unlink "$stem.$suffix";
}
my $pdf = "$stem.pdf";
say 'Wrote ' . colored(['black on_white'], $pdf);
