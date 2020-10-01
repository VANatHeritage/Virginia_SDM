# This script installs/updates packages used in the modelling process of this repository.
# Run it occasionally (especially after updating R itself) to keep packages up-to-date.
message("Installing/updating packages...")
r_files <- c(list.files(".", pattern = '\\.R$', ignore.case = T, recursive = F, full.names = T), 
  list.files("helper", pattern = '\\.R$', ignore.case = T, recursive = F, full.names = T))
r_files <- r_files[!basename(r_files) == "pkg_check.R"]
rllist <- list()
for (r in r_files) {
  suppressWarnings(rl <- readLines(r))
  rl2 <- paste(rl[grepl("library(", rl, fixed = T)], " ", sep = "")
  if (length(rl2) > 0) {
    rl3 <- regmatches(rl2, regexec("library\\((.*)\\)", rl2))
    rllist[[r]] <- unlist(lapply(rl3, function(x) gsub("[^[:alnum:]|\\.]", "", x[length(x)])))
  }
}
pkg_list <- sort(unique(unlist(rllist)))
# pkg_list <- c("RSQLite","rgdal","sp","rgeos","raster","maptools",
#               "ROCR","vcd","abind","foreign","randomForest",
#               "snow", "DBI", "knitr","RColorBrewer","rasterVis","xtable",
#               "git2r","spsurvey", "here","sf","dplyr","stringi","tmap","tmaptools","OpenStreetMap")
installed <- installed.packages()
to_inst <- pkg_list[!pkg_list %in% installed[,1]]

if (length(to_inst) > 0) {
  update.packages(oldPkgs=pkg_list[!pkg_list %in% to_inst], checkBuilt = TRUE, ask = FALSE, type = "binary")
  install.packages(to_inst, type = "binary")
} else {
  update.packages(oldPkgs=pkg_list, checkBuilt = TRUE, ask = FALSE, type = "binary")
}

rm(pkg_list, installed, to_inst)
