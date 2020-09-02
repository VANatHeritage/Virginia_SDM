# File: user_run_SDM.r
# Purpose: Run a new, full SDM model (all steps)

library(here)
rm(list=ls())

# Step 1: Setting for the model run

# species code (from lkpSpecies in modelling database. This will be the new folder name containing inputs/outputs)
# list.files(here("_data","occurrence"), full.names = F, recursive = F, pattern = ".shp$")
library(RSQLite)
nm_db_file <- here("_data", "databases", "SDM_lookupAndTracking.sqlite")
db <- dbConnect(SQLite(), nm_db_file)
spp.list <- sort(dbGetQuery(db, "SELECT sp_code s from lkpSpecies where modtype = 'T' AND sdm_status = 1;")$s)
dbDisconnect(db)
rm(nm_db_file, db)

# manual list
# spp.list <-  c("ammocaud")
spp.list 
for (model_species in spp.list) {

  print(model_species)
  
  # loc_scripts is your repository. Make sure your git repository is set to correct branch
  loc_scripts <- here()
  # The main modelling folder for inputs/outputs. All sub-folders are created during the model run (when starting with step 1)
  loc_model <- here("_data", "species")
  # Modeling database
  nm_db_file <- here("_data", "databases", "SDM_lookupAndTracking.sqlite")
  # locations file (presence reaches). Provide full path; File is copied to modeling folder and timestamped.
  nm_presFile <- here("_data", "occurrence", paste0(model_species, ".shp"))
  # env vars location [Terrestrial-only variable]
  loc_envVars = here("_data","env_vars","raster")
  # Name of background/envvars sqlite geodatabase, and base table name (2 length vector)
  nm_bkgPts <- c(here("_data","env_vars","tabular", "background.sqlite"), "background_VA") # last updated 2020-06-10
  # HUC spatial data set (shapefile) that is subsetted and used to define modeling area//range
  nm_HUC_file <- here("_data","other_spatial","feature","WBDHU10_HR.gpkg")
  # map reference boundaries
  #nm_refBoundaries = here("_data","other_spatial","feature", "US_States.shp")  # background grey reference lines in map
  nm_refBoundaries = here("_data","other_spatial", "feature", "sdmVA_pred_20170131.shp")
  
  # project overview - this appears in the first paragraph of the metadata
  project_overview = "The following metadata describes the SDM for a species tracked by the Virginia Natural Heritage Program (2020)."
  # model comment in database
  model_comments = ""
  # comment printed in PDF metadata
  metaData_comments = ""
  # your name
  modeller = "David Bucklin"
  # project_blurb = "Models developed for the MoBI project are intended to inform creation of a national map of biodiversity value, and we recommend additional refinement and review before these data are used for more targeted, species-specific decision making. In particular, many MoBI models would benefit from greater consideration of species data and environmental predictor inputs, a more thorough review by species experts, and iteration to address comments received."
  project_blurb <- ""
  
  # list non-standard variables to add to model run. Need to be already attributed in background points
  add_vars = NULL  # c("apiDistInt")
  # list standard variables to exclude from model run
  remove_vars = NULL  # c("impsur1", "impsur10", "impsur100") 
  # do you want to stop execution after each modeling step (script)?
  prompt = F
  
  # dissolve HUC level for defining ranges, based on HUC-10 interesections, so can be set to 2,4,6,8,10. Set NULL for automatic: intersecting HUC-10s + 1 HUC-10 buffer.
  huc_level = NULL
  
  # set wd and load function
  setwd(loc_scripts)
  source(here("helper", "run_SDM.R"))
  
  ##############
  # End step 1 #
  ##############
  
  # Step 2: execute a new model
  # Usage: For a full, new model run, provide all paths/file names to arguments 'loc_scripts' THROUGH 'modeller'.
  # RUN A NEW MODEL (ALL STEPS 1-5)
  
  run_SDM(
    model_species = model_species,
    loc_scripts = loc_scripts, 
    nm_presFile = nm_presFile,
    nm_db_file = nm_db_file, 
    loc_model = loc_model,
    loc_envVars = loc_envVars,
    nm_bkgPts = nm_bkgPts,
    nm_HUC_file = nm_HUC_file,
    nm_refBoundaries = nm_refBoundaries,
    project_overview = project_overview,
    model_comments = model_comments,
    metaData_comments = metaData_comments,
    modeller = modeller,
    add_vars = add_vars,
    remove_vars = remove_vars,
    project_blurb = project_blurb,
    huc_level = huc_level,
    prompt = prompt
  )
  
  # update sdm_status.
  library(RSQLite)
  nm_db_file <- here("_data", "databases", "SDM_lookupAndTracking.sqlite")
  db <- dbConnect(SQLite(), nm_db_file)
  dbExecute(db, paste0("UPDATE lkpSpecies SET sdm_status = 2 where sp_code = '", model_species, "';"))
  dbDisconnect(db)
  rm(nm_db_file, db)

}



#############################################################################
#############################################################################
#############################################################################

# Step 2-alternate: run additional model, or pick up from previous model run

# if using add_vars or remove_vars for a new model run, start at step 2.

# if you want to run a new model with the same input data as a previous run, start at step 3.

# If picking up from a previously started run, always
# provide the begin_step, model_species, and loc_model.
# You can also include any other arguments that you wish to change from 
# the previous run (e.g., model_comments or metaData_comments).
# 
# Note that you can manually update the scripts, if desired. 
# The scripts will automatically be accessed from 'loc_scripts' (if provided) 

# or the location that was specified for the original model run. 
library(here)
rm(list=ls())

# set project folder and species code for this run
model_species <- "bazznudi"
loc_model <- here("_data", "species")

# set wd and load function
loc_scripts <- here()
setwd(loc_scripts)
source(here("helper", "run_SDM.R"))
  

# example pick-up a model run at step 2 (same presence/bkgd data, new model with different variables)
# to add/remove variables, begin at step 2
# to just run new model, begin at step 3 (see next example)
run_SDM(
  begin_step = "2",
  model_species = model_species,
  loc_model = loc_model,
  add_vars = c("Isotherm","radequinx"),
  remove_vars = c("elevx10","radwinsol"),
  prompt = F
)

# example pick-up a model run at step 3; uses most recent settings from previous run_SDM run
run_SDM(
  begin_step = "3",
  model_species = model_species,
  loc_model = loc_model,
)

# example pick-up a model run at step 4c (metadata/comment update)
# Always picks up the most recent model run for the species.
run_SDM(
  begin_step = "4c",
  model_species = model_species,
  loc_model = loc_model,
  model_comments = "",
  metaData_comments = "",
  project_overview = "The following metadata describes the SDM for a species tracked by the Virginia Natural Heritage Program (2020).",
  project_blurb = ""
)

run_SDM(
  begin_step = "5",
  model_species = model_species,
  loc_model = loc_model
)


########## 
##########
##########

# TESTING / DEBUGGING ONLY

library(here)
rm(list=ls())

# Use the lines below for debugging (running line by line) for a certain script
# This loads the variables used in previous model run for the species, 
# so you need to have started a run_SDM() run in step 2 first.

# for scripts 1-3, run just the following 3 lines
model_species <- "caresp2"
load(here("_data","species",model_species,"runSDM_paths.Rdata"))
for(i in 1:length(fn_args)) assign(names(fn_args)[i], fn_args[[i]])

# if debugging script 4 or later, also load the output rdata file
model_rdata <- fn_args$modelrun_meta_data$model_run_name
load(here("_data","species",model_species,"outputs","rdata",paste0(model_rdata, ".Rdata")))
