#!/usr/bin/env perl

use 5.042;
no source::encoding;
#use re 'debugcolor';
use File::Temp 'tempfile';
use warnings FATAL => 'all';
use Cwd 'getcwd';
use List::MoreUtils 'first_index';
use autodie ':default';
use Util 'execute';
use latex 'write_latex_figure';
use Matplotlib::Simple 'plot';
use Term::ANSIColor;

=mission statement

This script plots output from Gromacs output files and puts all output into a LaTeX file

=cut

my @log_files = ('em.log', 'nvt.log', 'npt.log', 'md.log');
my @xvg_files = ('gyrate.xvg', 'rmsd_xray.xvg', 'mindist.xvg');
my @missing_files = grep {not -f $_} (@log_files, @xvg_files);
if (scalar @missing_files > 0) {
	p @missing_files;
	die 'the above files are not present or are not files.';
}
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
\listoffigures';
my ($tmp, $tmp_filename) = tempfile(DIR => '/tmp', SUFFIX => '.py', UNLINK => 0);
close $tmp;
my %log2title = (
	'npt.log' => 'Number of particles, Pressure, and Temperature are held constant',
	'nvt.log' => 'NVT ensemble (constant Number of particles, Volume, and Temperature)',
	'em.log'  => 'Energy Minimization',
	'md.log'  => 'Molecular Dynamics'
);foreach my $log (@log_files) {
	open my $fh, '<', $log;
	my @log = <$fh>;
	close $fh;
	chomp @log;
	my %input;
	my $first_input  = first_index { $_ eq 'Input Parameters:' } @log;
	foreach my $i ($first_input+1..$#log) { # save for later use
		last unless $log[$i] =~ m/^\h+[\w\-]+\h+=\h+\S/;
		$log[$i] =~ s/^\h+//;
		my @line = split /\h+=\h+/, $log[$i];
		if (scalar @line != 2) {
			p @line;
			die "Element $i of \"$log\" doesn't have 2 elements";
		}
		$input{$line[0]} = $line[1];
	}
#	my $first_energy = first_index { $_ =~ m/^\h+Step\h+Time\n/} @log; # prevent false/spurious matches
	my $newline_str = join ('', @log);
	my @energy_types = (
		'Bond', 'U-B', 'Proper Dih.', 'Improper Dih.', 'CMAP Dih.',
		'LJ-14', 'Coulomb-14', 'LJ (SR)', 'Coulomb (SR)','Coul. recip.',
		'Potential','Pressure (bar)','Constr. rmsd',
		'Position Rest.', # NPT only
		'Kinetic En.','Total Energy','Conserved En.','Temperature'
	);
	my $en_regex = '(Bond|U\-B|Proper\hDih\.|Improper\hDih\.|CMAP\hDih\.|LJ\-14|Coulomb\-14|LJ\h\(SR\)|Coulomb\h\(SR\)|Coul.\hrecip\.|Potential|Pressure\h\(bar\)|Constr\.\hrmsd|Total\hEnergy|Conserved\hEn\.|Temperature|Kinetic\hEn\.|Position\hRest\.)'; # energy regex
	my $nu_regex = '(-?[\d\.e\+\-]+)'; # numeric regex
	my @time = $newline_str =~ m/
	\h+Step\h+Time\h+\d+\h+([\d\.]+)
	\h+Energies\h\(kJ\/mol\)
	/xg;
	my $output_type;
	my @energies = $newline_str =~ m/
	Step\h+Time\h+\d+\h+[\d\.]+
	\h+Energies\h\(kJ\/mol\)
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	/xg;
	$output_type = 'EM' if scalar @energies > 0;
	if (scalar @energies == 0) {
		@energies = $newline_str =~ m/
	Step\h+Time\h+\d+\h+[\d\.]+
	\h+Energies\h\(kJ\/mol\)
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex
	/xg;
		$output_type = 'MD' if scalar @energies > 0;
	}
	if (scalar @energies == 0) {
		@energies = $newline_str =~ m/
	Step\h+Time\h+\d+\h+[\d\.]+
	\h+Energies\h\(kJ\/mol\)
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	
	\h+ $en_regex \h+ $en_regex \h+ $en_regex
	\h+ $nu_regex \h+ $nu_regex \h+ $nu_regex
	/xg;
		$output_type = 'NPT' if scalar @energies > 0;
	}
	if (scalar @energies == 0) {
		say $newline_str;
		die "failed to get any energy data from $log";
	}
	my (@plot, %n_to_get_numeric);
	if ($output_type eq 'EM') {
		%n_to_get_numeric = (
			Bond => 5,	'U-B' => 5,	'Proper Dih.' => 5,	'Improper Dih.' => 5,
			'CMAP Dih.' => 5,
			'LJ-14' => 5,'Coulomb-14' => 5,'LJ (SR)' => 5,'Coulomb (SR)' => 5,'Coul. recip.' => 5,'Potential' => 3,'Pressure (bar)' => 3,'Constr. rmsd' => 3,
		);
	} elsif ($output_type eq 'MD') {
		%n_to_get_numeric = (
			Bond => 5,	'U-B' => 5,	'Proper Dih.' => 5,	'Improper Dih.' => 5, 'CMAP Dih.' => 5,
			'LJ-14' => 5,'Coulomb-14' => 5,'LJ (SR)' => 5,'Coulomb (SR)' => 5,'Coul. recip.' => 5,'Potential' => 5,'Pressure (bar)' => 2,'Constr. rmsd' => 2,
			'Kinetic En.' => 5,	'Total Energy' => 5,'Conserved En.' => 5,'Temperature' => 5,
		);
	} elsif ($output_type eq 'NPT') {
		%n_to_get_numeric = (
			Bond => 5,	'U-B' => 5,	'Proper Dih.' => 5,	'Improper Dih.' => 5,
			'CMAP Dih.' => 5,
			'LJ-14' => 5,'Coulomb-14' => 5,'LJ (SR)' => 5,'Coulomb (SR)' => 5,'Coul. recip.' => 5,'Potential' => 5,
			'Kinetic En.'    => 5, 'Position Rest.' => 5,	'Constr. rmsd' => 3,
			'Total Energy' => 5,'Conserved En.' => 5,'Temperature' => 3,,'Pressure (bar)' => 3,
		);
	}
	foreach my $energy_type (grep {$newline_str =~ m/\Q$_\E/} @energy_types) {
		die "$energy_type has no defined step for $log" if not defined $n_to_get_numeric{$energy_type};
		my @indices = map {$_ + $n_to_get_numeric{$energy_type}} grep {$energies[$_] eq $energy_type} 0..$#energies;
		if ($indices[-1] > $#energies) {
			die
		}
		if (scalar @indices != scalar @time) {
			printf STDERR ("$energy_type has %u data points.\n", scalar @indices);
			die "$energy_type doesn't have the correct number of energies";
		}
		my $ylab = '(kJ/mol)';
		$ylab = 'bar' if $energy_type eq 'Pressure (bar)';
		$ylab = 'K'   if $energy_type eq 'Temperature';
		push @plot, {
			data => {
				$energy_type => [
					[@time],
					[@energies[@indices]]
				]
			},
			'plot.type' => 'plot',
			title       => $energy_type,
			'show.legend' => 0,
			'set.options' => { # set options overrides global settings
				$energy_type => 'color="red", linewidth=2',
			},
			xlabel => 'Time (ps)',
			ylabel => $ylab
		};
	}
	my $stem = $log;
	$stem =~ s/\.log$//;
	my $output_image_file = "$stem.svg";
	my $suptitle = uc $stem;
	plot({
		'input.file'      => $tmp_filename,
		execute           => 0,
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
}
my (%plot_data, %gy);
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
	execute           => 0,
	'input.file'      => $tmp_filename,
	data              => \%plot_data,
	'output.filename' => 'gyrate.svg',
	'plot.type'       => 'plot',
	set_figwidth      => 12,
	title             => 'Gyration',
	xlabel            => 'Time (ps)',
	ylabel            => 'Radius (nm)',
	xlim              => "0, $gy{'time'}[-1]" # avoid whitespace on right and left sides
});
undef %plot_data;
write_latex_figure({
	alignment    => '\centering',
	'image.file' => 'gyrate.svg',
	caption      => 'Radii of gyration',
	label        => "fig:gyrate",
	fh           => $tex,
	width        => '\textwidth'
});
my (@col, @time, %prop);
open $fh, '<', 'mindist.xvg';
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
	execute           => 0,
	'input.file'      => $tmp_filename,
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
undef @time;
write_latex_figure({
	alignment    => '\centering',
	'image.file' => 'mindist.svg',
	caption      => 'Periodic Image Distances',
	label        => 'fig:mindist',
	fh           => $tex,
	width        => '\textwidth'
});
open $fh, '<', 'rmsd_xray.xvg';
my @rmsd;
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
	execute           => 1,
	'input.file'      => $tmp_filename,
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
say $tex '\end{document}';
execute("pdflatex --draftmode $tex_filename");
execute("pdflatex --draftmode $tex_filename");
execute("pdflatex --draftmode $tex_filename");
execute("pdflatex $tex_filename");
my $pdf = $tex_filename;
$pdf =~ s/tex$/pdf/;
say 'Wrote ' . colored(['black on_white'], $pdf);
