# File: run_SDM.r
# Purpose: provide a function interface for running the SDM
#   process in this repository. 

# Usage: For a full, new model run, provide all paths/file names to arguments 'loc_scripts' THROUGH 'modeller'.

# If picking up from a previous run, provide the full file location to the saved rdata file (no file extension)
# holding these paths. For new runs, this file is automatically saved as "runSDM_paths" in the 
# 'loc_model' folder of the original run.
# Optional arguments for all runs include:
# 1. begin_step: specify as the prefix of the step to begin with: one of ("1","2","3","4","4b","4c","5"). Defaults to "1".
# 2. prompt: if TRUE, the function will stop after each script, and ask if you want to continue. Defaults to FALSE.

run_SDM <- function(
  loc_scripts,
  model_species,
  nm_presFile,
  nm_db_file,
  loc_model,
  loc_envVars,
  nm_bkgPts,
  nm_HUC_file,
  nm_refBoundaries,
  project_overview = "",
  model_comments = "",
  metaData_comments = "",
  modeller = NULL,
  begin_step = "1",
  add_vars = NULL,
  remove_vars = NULL,
  huc_level = NULL,
  project_blurb = NULL,
  prompt = FALSE
) {
  
  if ((hasArg(add_vars) | hasArg(remove_vars)) & !begin_step %in% c("1","2")) 
    stop("Need to begin on step 1 or 2 if adding or removing variables.")
  
  # check if new or picked-up run
  if (begin_step != "1") {
    message("Loading most recent saved runSDM settings...")
    load(paste0(loc_model, "/" , model_species, "/runSDM_paths.Rdata"))
    # re-write modified variables
    for (na in names(fn_args)) {
      if (eval(parse(text = paste0("hasArg(",na,")")))) fn_args[[na]] <- eval(parse(text=na))
    }
    # set presfile to a previously prepared presence file
    if (hasArg(nm_presFile)) fn_args$baseName <- gsub(".csv$", "", nm_presFile)
    rm(na)
    
  } else {
    baseName <- strsplit(basename(nm_presFile),"\\.")[[1]][[1]]
    baseName <- paste0(baseName, "_", gsub(" ","_",gsub(c("-|:"),"",as.character(Sys.time()))))
    fn_args <- list(
      loc_scripts = loc_scripts, 
      model_species = model_species,
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
      huc_level = huc_level,
      baseName = baseName,
      project_blurb = project_blurb)
  }
  
  # add comments for added/excluded vars
  if (!hasArg(model_comments)) model_comments <- fn_args$model_comments
  if (!hasArg(metaData_comments)) metaData_comments <- fn_args$metaData_comments
  if (!is.null(add_vars)) fn_args$add_vars <- add_vars
  if (!is.null(remove_vars)) fn_args$remove_vars <- remove_vars
  # save fn_args
  dir.create(paste0(loc_model, "/" , model_species), showWarnings = F)
  save(fn_args, file = paste0(loc_model, "/" , model_species, "/runSDM_paths.Rdata"))
  
  # assign objects
  for(i in 1:length(fn_args)) assign(names(fn_args)[i], fn_args[[i]])
  
  # check for missing packages
  req.pack <- c("RSQLite","rgdal","sp","rgeos","raster","maptools","ROCR","vcd","abind","git2r","sf",
                "foreign","randomForest","DBI","knitr","RColorBrewer","rasterVis","xtable")
  miss.pack <- req.pack[!req.pack %in% names(installed.packages()[,1])]
  if (length(miss.pack) > 0) {
    stop("Need to install the following package(s) before running this function: ", paste(miss.pack, collapse = ", "), ". Run script helper/pkg_check.R to download/update.")
  }
  
  # steps to run
  all_steps <- c("1","2","3","4","4b","4c","5")
  step_names <- c("1_pointsInPolys_cleanBkgPts.R",
                  "2_attributePoints.R",
                  "3_createModel.R",
                  "4_predictModelToStudyArea.R",
                  "4b_thresholdModel.R",
                  "4c_additMetadComments_rubricUpdate.r",
                  "5_createMetadata.R"
  )
  run_steps <- step_names[match(begin_step, all_steps) : length(all_steps)]
  
  if (!begin_step %in% c("1","2","3")) {
    model_rdata <- fn_args$modelrun_meta_data$model_run_name
    model_rdata_file <- paste0(loc_model, "/", model_species, "/outputs/rdata/", model_rdata, ".Rdata")
    if (!file.exists(model_rdata_file)) stop("No Rdata file exists for the model run `", model_rdata, "`. Need to start with `begin_step` of 1-3.")
    load(model_rdata_file)
    rm(model_rdata, model_rdata_file)
  }
  
  # run scripts
  for (scrpt in run_steps) {
    message(paste0("Running script ", scrpt , "..."))
    # reload variables
    for(i in 1:length(fn_args)) assign(names(fn_args)[i], fn_args[[i]])
    
    # run script
    source(paste(loc_scripts, scrpt, sep = "/"), local = TRUE)
    
    # clean up everything but loop objects
    rm(list=ls()[!ls() %in% c("scrpt","run_steps","prompt","modelrun_meta_data","fn_args")])
    
    message(paste0("Completed script ", scrpt , "..."))
    
    # ask for user input if prompt selected
    if (prompt & scrpt != "5_createMetadata.R") {
      continue <- readline(prompt = "Continue? (1=yes; 0=no):")
      while (!continue %in% c("0","1")) continue <- readline(prompt = "Try again. Continue? (1=yes; 0=no):")
      if (as.integer(continue) == 0) break("model run stopped")
    }
  }
}