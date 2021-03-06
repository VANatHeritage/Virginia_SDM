# File: 2_attributePoints.r
# Purpose: attribute environmental data to presence points

library(raster)
library(sf)
library(RSQLite)
library(snowfall)

# load data, QC ----
setwd(loc_envVars)

# get the rasters
raslist <- list.files(pattern = ".tif$", recursive = TRUE)

# get short names from the DB
# first shorten names in subfolders
raslist.short <- unlist(
  lapply(strsplit(raslist, "/"), function(x) {x[length(x)]})
)

# get MODTYPE
db <- dbConnect(SQLite(),dbname=nm_db_file)
SQLQuery <- paste0("SELECT MODTYPE m FROM lkpSpecies WHERE sp_code = '", model_species, "';")
modType <- dbGetQuery(db, SQLQuery)$m

# shrtNms contains all variables in loc_envVars. Merged with Database info using fileName (no path, with file extension)
db <- dbConnect(SQLite(),dbname=nm_db_file)
SQLQuery <- paste0("select gridName, fileName, use_", modType, " use from lkpEnvVars;")
evs <- dbGetQuery(db, SQLQuery)
shrtNms <- merge(data.frame(fileName = raslist.short, path = raslist, fullpath = paste0(loc_envVars, "/", raslist), 
                            stringsAsFactors = FALSE), evs, all.x = T)
dbDisconnect(db)

# ###
# gridlist <- as.list(paste(loc_envVars,shrtNms$path,sep = "/"))
# #nm <- substr(shrtNms$path,1,nchar(shrtNms$path) - 4) # remove .tif extension
# names(gridlist) <- raslist.short
# 
# gridlist <- gridlist[order(names(gridlist))]
# names(gridlist) <- shrtNms[order(shrtNms$fileName),"gridName"]
# 
# nulls <- gridlist[is.na(names(gridlist))]
#if(length(nulls) > 0){
if (any(is.na(shrtNms$gridName))) {
  print(shrtNms$fileName[is.na(shrtNms$gridName)])
  stop("Some grids are not in DB.")
}

# check to make sure there are no names greater than 10 chars
nmLen <- nchar(shrtNms$gridName)
max(nmLen) # if this result is greater than 10, you've got a renegade

# Set working directory to the random points location
setwd(paste0(loc_model, "/", model_species, "/inputs"))

shpf <- st_read(paste0("presence/", baseName, "_RanPts.shp"),quiet = T)

# if modtype is both (B), flip it to A or T
# what git branch are we on?
#branches <- system("git branch", intern = TRUE)
#activeBranch <- branches[grep("\\*", branches)]
#activeBranch <- sub("\\*", "", activeBranch)
#activeBranch <- gsub(" ", "", activeBranch)
activeBranch <- git2r::repository_head()$name

if(modType == "B"){
  if(activeBranch == "terrestrial") modType <- "T"
  if(activeBranch == "aquatic") modType <- "A"
}

# gridlistSub is a running list of variables to use, using gridName from database
gridlistSub <- unique(shrtNms$gridName[shrtNms$use==1])

## account for add/remove vars. All matching done on the fly with tolower; actual values do not change.
if (!is.null(add_vars)) {
  if (!all(tolower(add_vars) %in% tolower(shrtNms$gridName))) {
    stop("Some environmental variables listed in `add_vars` were not found in `nm_EnvVars` dataset: ",
         paste(add_vars[!tolower(add_vars) %in% tolower(shrtNms$gridName)], collapse = ", "), ".")
  }
  # add the variables
  add_vars_df <- shrtNms[tolower(shrtNms$gridName) %in% tolower(add_vars),c("gridName")]
  gridlistSub <- c(gridlistSub, add_vars_df)
}
if (!is.null(remove_vars)) {
  if (!all(tolower(remove_vars) %in% tolower(shrtNms$gridName))) {
    message("Note: Some environmental variables listed in `remove_vars` were not found in the `nm_EnvVars` dataset: ",
            paste(remove_vars[!tolower(remove_vars) %in% tolower(shrtNms$gridName)], collapse = ", "), ".")
  } 
  # remove the variables
  gridlistSub <- gridlistSub[!tolower(gridlistSub) %in% tolower(remove_vars)]
}

# remove duplicates, then subset
gridlistSub <- gridlistSub[!duplicated(gridlistSub)]
fullL1 <- shrtNms[tolower(shrtNms$gridName) %in% tolower(gridlistSub),]
fullL1$subfolder <- unlist(lapply(fullL1$path, FUN = function(x) {
  s <- strsplit(x, "/")[[1]] 
  if (length(s) > 1) paste0(s[1],".") else ""}
))
fullL <- as.list(fullL1$fullpath)
names(fullL) <- paste(fullL1$subfolder, fullL1$gridName, sep = "")


# Could use this script here crop/mask rasters
#source(paste0(loc_scripts, "/helper/crop_mask_rast.R"), local = TRUE)
#envStack <- stack(newL)

# make grid stack with subset
envStack <- stack(fullL)
rm(fullL, fullL1, gridlistSub, modType, activeBranch)

# extract raster data to points ----

# Extract values to a data frame - multicore approach using snowfall
# First, convert raster stack to list of single raster layers
s.list <- unstack(envStack)
names(s.list) <- names(envStack)
# Now, create a R cluster using all the machine cores minus one
sfInit(parallel=TRUE, cpus=parallel:::detectCores()-1)
# Load the required packages inside the cluster
sfLibrary(raster)
sfLibrary(sf)
# Run parallelized 'extract' function and stop cluster
e.df <- sfSapply(s.list, extract, y=shpf, method = "simple")
sfStop()

points_attributed <- st_sf(cbind(data.frame(shpf), data.frame(e.df)))

# method without using snowfall
#points_attributed <- extract(envStack, shpf, method="simple", sp=TRUE)

# temporal variables data handling
pa <- points_attributed
tv <- names(pa)[grep(".",names(pa), fixed = TRUE)]
if (length(tv) > 0) {
  tvDataYear <- do.call(rbind.data.frame, strsplit(tv, "_|\\."))
  names(tvDataYear) <- c("dataset", "date", "envvar")
  tvDataYear$date <- as.numeric(as.character(tvDataYear$date))
  
  # loop over temporal variables
  for (i in unique(tvDataYear$envvar)) {
    tvDataYear.s <- subset(tvDataYear, tvDataYear$envvar == i)
    yrs <- sort(unique(tvDataYear.s$date))
    
    # add 0.1 to occurrence date/year, avoiding cases where date is exactly between two years
    closestYear <- unlist(lapply(as.numeric(pa$date) + 0.1, FUN = function(x) {
      y <- abs(x - yrs)
      yrs[which.min(y)]}))
    
    # DECIDE IF THERE SHOULD BE A CUTOFF FOR WHEN OBSERVATION YEAR IS NOT CLOSE TO ANY OF THE DATES #
    
    vals <- unlist(lapply(1:length(pa$date), FUN = function(x) {
      eval(parse(text = paste0("pa$", tvDataYear.s$dataset[1],"_",closestYear[x],".",i, "[", x ,"]")
      ))
    }))
    
    # add to pa
    eval(parse(text = paste0("pa$", i, " <- vals")))
  }
  
  points_attributed <- pa[-grep(".", names(pa), fixed = TRUE)]
}
suppressWarnings(rm(tv,tvDataYear,tvDataYear.s, yrs, closestYear, vals, pa))

# write it out to the att db
dbName <- paste(baseName, "_att.sqlite", sep="")
db <- dbConnect(SQLite(), paste0("model_input/",dbName))
att_dat <- points_attributed
st_geometry(att_dat) <- NULL

dbWriteTable(db, paste0(baseName, "_att"), att_dat, overwrite = T)
dbDisconnect(db)
rm(db)

