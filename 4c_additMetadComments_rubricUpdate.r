# File: 4c_additMetadComments_rubricUpdate.r
# Purpose: this script is for adding an extra paragraph to the metadata pdf,
# making any specific comments you have for the specific model you
# are working with.

# the intent here is for the database to store comments from different
# modeling runs if that's what you want, or give you the ability to 
# just update the comments when you update the model. 

# this script also updates the rubric table, based on information from the model run (TSS) 
# and the tracking DB
# this portion requires an ODBC connection (named mobi_spp_tracking) set up in the OS with the tracking DB

library(RSQLite)
library(RODBC)

# load Rdata ----
setwd(loc_model)
setwd(paste0(model_species,"/outputs"))
load(paste0("rdata/", modelrun_meta_data$model_run_name,".Rdata"))

for(i in 1:length(modelrun_meta_data)) assign(names(modelrun_meta_data)[i], modelrun_meta_data[[i]])

## Additional Metadata Comments: get any current documentation ----
db <- dbConnect(SQLite(),dbname=nm_db_file)

SQLquery <- paste("SELECT * ",
                  " FROM tblModelResults ",
                  "WHERE model_run_name ='", model_run_name , "'; ", sep="")
dat.in.db <- dbGetQuery(db, statement = SQLquery)
newText <- fn_args$metaData_comments
# add/remove vars comment
if (!is.null(fn_args$add_vars)) {
  add.comm <- paste0(" Non-standard variables (", paste(fn_args$add_vars, collapse = ", "), ") were included in this model.")
  newText <- paste0(newText, add.comm)
}
if (!is.null(fn_args$remove_vars)) {
  add.comm <- paste0(" The standard variables (", paste(fn_args$remove_vars, collapse = ", "), ") were excluded from this model.")
  newText <- paste0(newText, add.comm)
}
#clean up newline chars, send it to the DB
newText <- gsub("\n", " ", newText)
# update row if necessary
if (dat.in.db$metadata_comments != newText) {
  SQLquery <- paste("UPDATE tblModelResults ",
                    "SET metadata_comments = '", newText, 
                    "' WHERE model_run_name = '", 
                    model_run_name, "';", sep = "")
  dbExecute(db, SQLquery)
}

### WORKING VA EDITS 2019-04-19

## update Model Evaluation and Use data (rubric table) ----
# get most recent data from the tracking DB for two of the rubric table fields that may vary
mobi <- F
if (mobi) {
  cn <- odbcConnect("mobi_spp_tracking")
  sql <- paste0("SELECT FinalSppList.ELEMENT_GLOBAL_ID, LocalityData.pres_dat_eval_rubric, 
                LocalityData.bison_use, LocalityData.gbif_use, LocalityData.inat_use, 
                LocalityData.other_use, LocalityData.MJD_sufficient, LocalityData.MJD_only, LocalityData.status
                FROM FinalSppList INNER JOIN LocalityData ON FinalSppList.ELEMENT_GLOBAL_ID = LocalityData.EGT_ID
                WHERE (((FinalSppList.ELEMENT_GLOBAL_ID)= ", ElementNames$EGT_ID, "));")
  localityData <- sqlQuery(cn, sql)
  
  sql <- paste0("SELECT Reviewer.EGT_ID, Reviewer.response, Reviewer.date_completed
                FROM Reviewer
                WHERE (((Reviewer.EGT_ID)= ", ElementNames$EGT_ID, " ));")
  reviewerData <- sqlQuery(cn, sql)
  close(cn)
  rm(cn)
} else{
  localityData <- data.frame(ELEMENT_GLOBAL_ID=NA, pres_dat_eval_rubric=NA, 
                             bison_use=0, gbif_use=0, inat_use=0, 
                             other_use=0, MJD_sufficient=NA, MJD_only=1, status=NA)
  reviewerData <- data.frame(EGT_ID=ElementNames$EGT_ID, response=0, date_completed=NA)
}

# fill status if it is NA
localityData[is.na(localityData$status),"status"] <- "in progress"

if(localityData$status == "complete"){
  # if complete, take scoring assessment from DB
  #1 = caution, 2 = acceptible, 3 = ideal
  dataQuality <- localityData$pres_dat_eval_rubric
} else if(sum(localityData[,c("bison_use","gbif_use","inat_use","other_use")]) > 0) {
  if(localityData$MJD_only == 1){
    #this really means 'mjd_use' in the DB, not 'mjd_only'
    # if any of the BIG data are tagged for use as well as the MJD data, tag it acceptible
    dataQuality <- 2
  } else {
    # if no MJD data, tag as caution
    dataQuality <- 1
  }
} else if(!sum(localityData[,c("bison_use","gbif_use","inat_use","other_use")]) > 0) {
  if(localityData$MJD_only == 1){ 
    #this really means 'mjd_use' in the DB, not 'mjd_only'
    # if only MJD data tagged to use
    dataQuality <- 3
  } else {
    #if nothing is tagged in DB, assume a mix of records
    dataQuality <- 2
  }
}
dqMatrix <- data.frame("dataQuality" = c(1,2,3),
                       "dqAttribute" = c("C","A","I"),
                       "dqComments" = c("Data taken from outside sources and may or may not be vetted for accuracy or weighted for spatial representation.",
                                        "Heritage Network data augmented with outside data which may or may not be vetted for accuracy or weighted for spatial representation.",
                                        "Heritage Network data are vetted for accuracy and weighted for spatial representation."))
dqUpdate <- dqMatrix[match(dataQuality, dqMatrix$dataQuality),]
#push it up to DB
sql <- paste0("update lkpSpeciesRubric set spdata_dataqual = '", dqUpdate$dqAttribute, 
              "', spdata_dataqualNotes = '", dqUpdate$dqComments, 
              "' where EGT_ID = ", ElementNames$EGT_ID, " ;")
dbExecute(db, statement = sql)
## performance
prfmcMatrix <- data.frame("pAttribute" = c("C","A"),
                          "pComments" = c("Model TSS < 0.6, or not measurable due to low sample size. Mapped model output is evaluated for ecological plausibility by expert review.",
                                          "Model TSS >= 0.6. Mapped model output is evaluated for ecological plausibility by expert review."))
if (length(group$vals)>2) prfmAtt <- ifelse(tss.summ$mean<=0.6, "C", "A") else prfmAtt <- "C"
prfmUpdate <- prfmcMatrix[match(prfmAtt, prfmcMatrix$pAttribute),]
sql <- paste0("update lkpSpeciesRubric set process_perform = '", prfmUpdate$pAttribute, 
              "', process_performNotes = '", prfmUpdate$pComments, 
              "' where EGT_ID = ", ElementNames$EGT_ID, " ;")
dbExecute(db, statement = sql)
## model review
modRev <- sum(reviewerData$response)
revMatrix <- data.frame("rAttribute" = c("C","A"),
                        "rComments" = c("Model was not reviewed by regional, taxonomic experts.",
                                        "Model was reviewed by regional, taxonomic experts."))
revAtt <- ifelse(sum(reviewerData$response) > 0 , "A", "C")
revUpdate <- revMatrix[match(revAtt, revMatrix$rAttribute),]
sql <- paste0("update lkpSpeciesRubric set process_review = '", revUpdate$rAttribute, 
              "', process_reviewNotes = '", revUpdate$rComments, 
              "' where EGT_ID = ", ElementNames$EGT_ID, " ;")
dbExecute(db, statement = sql)

## clean up ----
dbDisconnect(db)
