% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/model2netcdf.FATES.R
\name{model2netcdf.FATES}
\alias{model2netcdf.FATES}
\title{Code to convert FATES netcdf output into into CF standard}
\usage{
model2netcdf.FATES(outdir, sitelat, sitelon, start_date, end_date)
}
\arguments{
\item{outdir}{Location of FATES model output}

\item{sitelat}{Latitude of the site}

\item{sitelon}{Longitude of the site}

\item{start_date}{Start time of the simulation}

\item{end_date}{End time of the simulation}
}
\examples{
 
\dontrun{
example.output <- system.file("case.clm2.h0.2004-01-01-00000.nc",package="PEcAn.FATES")
model2netcdf.FATES(outdir="~/",sitelat=42.56341,sitelon=289.1853,start_date="2004-01-01 00:00:00",
end_date="2005-12-31 00:00:00")
}

}
\author{
Michael Dietze, Shawn Serbin
}

