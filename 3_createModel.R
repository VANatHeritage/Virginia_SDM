# File: 3_createModel.R
# Purpose: to create the random forest model. This includes:
# - create initial model to remove poorest performing env vars
# - validate using leave-one-out jackknifing
# - create a final model using all presence points, stratify by EO using RA
# - build partial plots of top performing env vars for metadata output

library(RSQLite)
library(ROCR)    #for ROC plots and stats
library(vcd)     #for kappa stats
library(abind)   #for collapsing the nested lists
library(foreign) #for reading dbf files
library(randomForest)
library(snow)
source(paste0(loc_scripts, "/helper/modelrun_meta_data.R"), local = T) # generates modelrun_meta_data

setwd(loc_model)
dir.create(paste0(model_species,"/outputs/rdata"), recursive = T, showWarnings = F)
setwd(paste0("./",model_species,"/inputs"))

# read data from the att db
dbName <- paste(baseName, "_att.sqlite", sep="")
db <- dbConnect(SQLite(), paste0("model_input/",dbName))

tableName <- paste0(baseName, "_att")
df.in <- dbReadTable(db, tableName)

# get the background data from the DB
tableName <- paste0(nm_bkgPts[2], "_clean")
df.abs <- dbReadTable(db, tableName)
dbDisconnect(db)

# write model input data to database before any other changes made
db <- dbConnect(SQLite(),dbname=nm_db_file)

# set the seed before validation loops
set.seed(seed)

# get species info
SQLquery <- paste("SELECT scientific_name SciName, common_name CommName, sp_code Code, broad_group Type, egt_id, g_rank, rounded_g_rank, s_rank, rounded_s_rank FROM lkpSpecies WHERE sp_code = '", model_species,"';", sep="")
ElementNames <- as.list(dbGetQuery(db, statement = SQLquery)[1,])

tblModelInputs <- data.frame(table_code = baseName, EGT_ID = ElementNames$EGT_ID, datetime = as.character(Sys.time()),
                             filename_pres = nm_presFile, filename_bkgd = paste(nm_bkgPts, collapse = "."),
                             feat_count = length(unique(df.in$stratum)), 
                             feat_grp_count = length(unique(df.in$group_id)), 
                             obs_count = length(df.in[,1]), bkgd_count = length(df.abs[,1]),
                             range_area_sqkm = NA)
dbExecute(db, paste0("DELETE FROM tblModelInputs where table_code = '", baseName, "';")) # remove any previously prepped dataset entry
dbWriteTable(db, "tblModelInputs", tblModelInputs, append = T)
envvar_list <- dbGetQuery(db, "SELECT gridname g from lkpEnvVars;")$g

#also get correlated env var information
SQLquery <- "SELECT gridName, correlatedVarGroupings FROM lkpEnvVars WHERE correlatedVarGroupings IS NOT NULL order by correlatedVarGroupings;"
corrdEVs <- dbGetQuery(db, statement = SQLquery)

dbDisconnect(db)
rm(db)

# get an original list of env-vars for later writing to tblVarsUsed
envvar_list <- names(df.in)[names(df.in) %in% envvar_list] # gets a list of environmental variables
df.abs <- df.abs[envvar_list]

#make sure we don't have any NAs
df.in <- df.in[complete.cases(df.in[,!names(df.in) %in% c("obsdate","date")]),]  # to ensure missing dates are not excluding records
df.abs <- df.abs[complete.cases(df.abs),]

# align data sets, QC ----
# add some fields to each
df.in <- cbind(df.in, pres=1)
df.abs$stratum <- "pseu-a"
df.abs <- cbind(df.abs, GROUP_ID="pseu-a", 
					pres=0, RA="high", SPECIES_CD="background")

# lower case column names
names(df.in) <- tolower(names(df.in))
names(df.abs) <- tolower(names(df.abs))

# get a list of env vars from the folder used to create the raster stack
raslist <- list.files(path = loc_envVars, pattern = ".tif$", recursive = TRUE)

# get short names from the DB
# first shorten names in subfolders (temporal vars). NOT FULLY TESTED
raslist.short <- unique(unlist(
  lapply(strsplit(raslist, "/"), function(x) {x[length(x)]})
))

db <- dbConnect(SQLite(),dbname=nm_db_file)
SQLQuery <- "select gridName, fileName from lkpEnvVars;"
evs <- dbGetQuery(db, SQLQuery)
# restrict to rasters in folder
shrtNms <- merge(data.frame(fileName = raslist.short), evs)

# get the env vars used by df.in
# assumes all env vars in df.in are accounted for by DB and in ras folders
shrtNms <- shrtNms[tolower(shrtNms$gridName) %in% names(df.in),]

# trust that the desired env vars are in df.in
rasnames <- tolower(shrtNms$gridName)

# get a list of all distance-to env vars
SQLquery <- "SELECT gridName FROM lkpEnvVars WHERE distToGrid = 1;"
dtGrids <- dbGetQuery(db, statement = SQLquery)

# clean up
#options(op)
dbDisconnect(db)
rm(db)

# Remove irrelevant distance-to grids ----
# check if pres points are VERY far away from any of the dist-to grids
#   (this can cause erroneous, non-biological relationships that should
#    not be driving the model. Group decision to remove.)

# get the ones we are using here
dtRas <- rasnames[rasnames %in% tolower(dtGrids$gridName)]
# what's the closest distance for each?
dtRas.min <- apply(as.data.frame(df.in[,dtRas]), 2, min)
# remove those whose closest distance is greater than 10km
dtRas.sub <- dtRas.min[dtRas.min > 5000]
rasnames <- rasnames[!rasnames %in% names(dtRas.sub)]

# clean up, merge data sets -----
# this is the full list of fields, arranged appropriately
colList <- c("species_cd","group_id","pres","stratum", "ra", rasnames)

####c("UID", "GROUP_ID", "SPECIES_CD", "RA", "OBSDATE")

# if colList gets modified, 
# also modify the locations for the independent and dependent variables, here
depVarCol <- 3
indVarCols <- c(6:length(colList))

#re-arrange
df.in <- df.in[,colList]
df.abs <- df.abs[,colList]

# row bind the pseudo-absences with the presence points
df.abs$group_id <- factor(df.abs$group_id)
df.full <- rbind(df.in, df.abs)

# reset these factors
df.full$stratum <- factor(df.full$stratum)
df.full$group_id <- factor(df.full$group_id)
if (length(levels(df.full$group_id))-1 < 5 & length(levels(df.full$group_id)) < length(levels(df.full$stratum))) {
  message("Performing cross validation by-polygon...")
  cv.by <- "stratum" 
} else {
  cv.by <- "group_id"
}
df.full$pres <- factor(df.full$pres)
df.full$ra <- factor(tolower(as.character(df.full$ra)))
df.full$species_cd <- factor(df.full$species_cd)

# make samp size groupings ----
EObyRA <- unique(df.full[,c(cv.by,"ra")])
EObyRA$sampSize[EObyRA$ra == "very high"] <- 5
EObyRA$sampSize[EObyRA$ra == "high"] <- 4
EObyRA$sampSize[EObyRA$ra == "medium"] <- 3
EObyRA$sampSize[EObyRA$ra == "low"] <- 2
EObyRA$sampSize[EObyRA$ra == "very low"] <- 1

# there appear to be cases where more than one 
# RA is assigned per EO. Handle it here by 
# taking max value
EObySS <- aggregate(EObyRA$sampSize, by=list(EObyRA[,cv.by]), max)
# set the background pts to the sum of the EO samples
names(EObySS) <- c(cv.by,"sampSize")
# EObySS$sampSize[EObySS[,cv.by] == "pseu-a"] <- sum(EObySS[!EObySS[,cv.by] == "pseu-a", "sampSize"])

sampSizeVec <- EObySS$sampSize
names(sampSizeVec) <- as.character(EObySS[,cv.by])
# reset sample sizes to number of points, when it is smaller than desired sample size
# This is only relevant when complete.cases may have removed some points from an already-small set of points
totPts <- table(df.full[,cv.by])
for (i in names(sampSizeVec)) if (sampSizeVec[i] >= totPts[i]) sampSizeVec[i] <- max(totPts[i] - 1, 1) 
  # make sure sample size at least (1) less than total points, avoiding case where no data is left for internal RF OOB
sampSizeVec["pseu-a"] <- sum(sampSizeVec[!names(sampSizeVec) %in% "pseu-a"])

##
# tune mtry ----
# run through mtry twice
mtry <- NULL
while (is.null(mtry)) {
try({
x <- tuneRF(df.full[,indVarCols],
             y=df.full[,depVarCol],
             ntreeTry = 300, stepFactor = 2, mtryStart = 6,
            strata = df.full[,cv.by], sampsize = sampSizeVec, replace = TRUE)

newTry <- x[x[,2] == min(x[,2]),1]

y <- tuneRF(df.full[,indVarCols],
            y=df.full[,depVarCol],
            ntreeTry = 300, stepFactor = 1.5, mtryStart = max(newTry),
            strata = df.full[,cv.by], sampsize = sampSizeVec, replace = TRUE)

mtry <- max(y[y[,2] == min(y[,2]),1])
rm(x,y)
})
}
##
# Remove the least important env vars ----
##

ntrees <- 1000
rf.find.envars <- randomForest(df.full[,indVarCols],
                        y=df.full[,depVarCol],
                        importance=TRUE,
                        ntree=ntrees,
                        mtry=mtry,
                        strata = df.full[,cv.by], sampsize = sampSizeVec, replace = TRUE)

impvals <- importance(rf.find.envars, type = 1)
OriginalNumberOfEnvars <- length(impvals)

# first remove the bottom of the correlated vars
corrdEVs <- corrdEVs[tolower(corrdEVs$gridName) %in% row.names(impvals),]
for(grp in unique(corrdEVs$correlatedVarGroupings)){
  vars <- tolower(corrdEVs[corrdEVs$correlatedVarGroupings == grp,"gridName"])
  imp.sub <- impvals[rownames(impvals) %in% vars,, drop = FALSE]
  suppressWarnings(varsToDrop <- imp.sub[!imp.sub == max(imp.sub),, drop = FALSE])
  impvals <- impvals[!rownames(impvals) %in% rownames(varsToDrop),,drop = FALSE]
}
rm(vars, imp.sub, varsToDrop)

# set the percentile, here choosing above 25% percentile
envarPctile <- 0.25
y <- quantile(impvals, probs = envarPctile)
impEnvVars <- impvals[impvals > y,]
subsetNumberofEnvars <- length(impEnvVars)
rm(y)
# which columns are these, then flip the non-envars to TRUE
impEnvVarCols <- names(df.full) %in% names(impEnvVars)
impEnvVarCols[1:5] <- TRUE
# subset!
df.full <- df.full[,impEnvVarCols]
# reset the indvarcols object
indVarCols <- c(6:length(names(df.full)))

##
# code above is for removing least important env vars
##

# prep for validation loop ----
#now that entire set is cleaned up, split back out to use any of the three DFs below
df.in2 <- subset(df.full,pres == "1")
df.abs2 <- subset(df.full, pres == "0")
df.in2$stratum <- factor(df.in2$stratum)
df.abs2$stratum <- factor(df.abs2$stratum)
df.in2$group_id <- factor(df.in2$group_id)
df.abs2$group_id <- factor(df.abs2$group_id)
df.in2$pres <- factor(df.in2$pres)
df.abs2$pres <- factor(df.abs2$pres)

#reset the row names, needed for random subsetting method of df.abs2, below
row.names(df.in2) <- 1:nrow(df.in2)
row.names(df.abs2) <- 1:nrow(df.abs2)

#how many polygons do we have?
numPys <-  nrow(table(df.in2$stratum))
#how many EOs do we have?
numEOs <- nrow(table(df.in2$group_id))

#initialize the grouping list, and set up grouping variables
#if we have fewer than 10 EOs, move forward with jackknifing by polygon, otherwise
#jackknife by EO.
group <- vector("list")
# group$colNm <- ifelse(numEOs < 10,"stratum","group_id")
# group$JackknType <- ifelse(numEOs < 10,"polygon","element occurrence")
# if(numEOs < 10) {
# 		group$vals <- unique(df.in2$stratum)
# } else {
# 		group$vals <- unique(df.in2$group_id)
# }
## TODO: bring back by-polygon validation. SampSize needs to be able to handle this to make it possible
# only validate by EO at this time:
group$colNm <- cv.by
group$JackknType <- ifelse(cv.by == "stratum", "polygon", "polygon group")
group$vals <- unique(df.in2[,cv.by])

#reduce the number of trees if group$vals has more than 30 entries #commented out to be parallel with aquatic
#this is for validation
# if(length(group$vals) > 30) {
# 	ntrees <- 750
# } else {
# 	ntrees <- 1000
# }

##initialize the Results vectors for output from the jackknife runs
trRes <- vector("list",length(group$vals))
   names(trRes) <- group$vals[]
evSet <- vector("list",length(group$vals))
   names(evSet) <- group$vals[]	   
evRes <- vector("list",length(group$vals))
   names(evRes) <- group$vals[]
t.f <- vector("list",length(group$vals))
   names(t.f) <- group$vals[]
t.ctoff <- vector("list",length(group$vals))
   names(t.ctoff) <- group$vals[]
v.rocr.rocplot <- vector("list",length(group$vals))
   names(v.rocr.rocplot) <- group$vals[]
v.rocr.auc <- vector("list",length(group$vals))
   names(v.rocr.auc) <- group$vals[]
v.y <- vector("list",length(group$vals))
   names(v.y) <- group$vals[]
v.kappa <- vector("list",length(group$vals))
   names(v.kappa) <- group$vals[]
v.tss <- vector("list",length(group$vals))
   names(v.tss) <- group$vals[]
v.OvAc <- vector("list",length(group$vals))
   names(v.OvAc) <- group$vals[]
t.importance <- vector("list",length(group$vals))
   names(t.importance) <- group$vals[]
t.rocr.pred <- vector("list",length(group$vals))
   names(t.rocr.pred) <- group$vals[]
v.rocr.pred <- vector("list",length(group$vals))
   names(v.rocr.pred) <- group$vals[]
   
#######
## This is the validation loop. ----
## it creates a model for all-but-one group (EO, polygon, or group),
## tests if it can predict that group left out,
## then moves on to another group, cycling though all groups
## Validation stats in tabular form are the final product.
#######
      
if(length(group$vals)>1){
	for(i in 1:length(group$vals)){
		   # Create an object that stores the select command, to be used by subset.
		  trSelStr <- parse(text=paste(group$colNm[1]," != '", group$vals[[i]],"'",sep=""))
		  evSelStr <- parse(text=paste(group$colNm[1]," == '", group$vals[[i]],"'",sep=""))
		   # apply the subset. do.call is needed so selStr can be evaluated correctly
		  trSet <- do.call("subset",list(df.in2, trSelStr))
		  evSet[[i]] <- do.call("subset",list(df.in2, evSelStr))
		   # use sample to grab a random subset from the background points (max at 25% of the full set).
		  BGsampSz <- min(nrow(evSet[[i]]), round(nrow(df.abs2)*0.25))
		  evSetBG <- df.abs2[sample(nrow(df.abs2), BGsampSz , replace = FALSE, prob = NULL),]
		   # get the other portion for the training set
		  TrBGsamps <- attr(evSetBG, "row.names") #get row.names as integers
		  trSetBG <-  df.abs2[-TrBGsamps,]  #get everything that isn't in TrBGsamps
		   # join em, clean up
		  trSet <- rbind(trSet, trSetBG)
		  trSet[,cv.by] <- factor(trSet[,cv.by])
		  evSet[[i]] <- rbind(evSet[[i]], evSetBG)
		  
		  ssVec <- sampSizeVec[!names(sampSizeVec) == group$vals[[i]]]
		  # re-calc pseudo-absence samples to match input training samples
		  ssVec["pseu-a"] <- sum(ssVec[!names(ssVec) %in% "pseu-a"])
		  
		  rm(trSetBG, evSetBG)
		  
		  trRes[[i]] <- randomForest(trSet[,indVarCols],y=trSet[,depVarCol],
		                             importance=TRUE,ntree=ntrees,mtry=mtry,
		                             strata = trSet[,group$colNm], sampsize = ssVec, replace = TRUE
		                             )
		  
		  # run a randomForest predict on the validation data
		  evRes[[i]] <- predict(trRes[[i]], evSet[[i]], type="prob")
		   # use ROCR to structure the data. Get pres col of evRes (= named "1")
		  v.rocr.pred[[i]] <- prediction(evRes[[i]][,"1"],evSet[[i]]$pres)
		   # extract the auc for metadata reporting
		  v.rocr.auc[[i]] <- performance(v.rocr.pred[[i]], "auc")@y.values[[1]]
			cat("finished run", i, "of", length(group$vals), "\n")
	}

	# restructure validation predictions so ROCR will average the figure
	v.rocr.pred.restruct <- v.rocr.pred[[1]]
	#send in the rest
	for(i in 2:length(v.rocr.pred)){
		v.rocr.pred.restruct@predictions[[i]] <- v.rocr.pred[[i]]@predictions[[1]]
		v.rocr.pred.restruct@labels[[i]] <- v.rocr.pred[[i]]@labels[[1]]
		v.rocr.pred.restruct@cutoffs[[i]] <- v.rocr.pred[[i]]@cutoffs[[1]]
		v.rocr.pred.restruct@fp[[i]] <- v.rocr.pred[[i]]@fp[[1]]
		v.rocr.pred.restruct@tp[[i]] <- v.rocr.pred[[i]]@tp[[1]]
		v.rocr.pred.restruct@tn[[i]] <- v.rocr.pred[[i]]@tn[[1]]
		v.rocr.pred.restruct@fn[[i]] <- v.rocr.pred[[i]]@fn[[1]]
		v.rocr.pred.restruct@n.pos[[i]] <- v.rocr.pred[[i]]@n.pos[[1]]
		v.rocr.pred.restruct@n.neg[[i]] <- v.rocr.pred[[i]]@n.neg[[1]]
		v.rocr.pred.restruct@n.pos.pred[[i]] <- v.rocr.pred[[i]]@n.pos.pred[[1]]
		v.rocr.pred.restruct@n.neg.pred[[i]] <- v.rocr.pred[[i]]@n.neg.pred[[1]]
	}

	# run a ROC performance with ROCR
	v.rocr.rocplot.restruct <- performance(v.rocr.pred.restruct, "tpr","fpr")
	# send it to perf for the averaging lines that follow
	perf <- v.rocr.rocplot.restruct

	## for infinite cutoff, assign maximal finite cutoff + mean difference
	## between adjacent cutoff pairs  (this code is from ROCR)
	if (length(perf@alpha.values)!=0) perf@alpha.values <-
		lapply(perf@alpha.values,
			function(x) { isfin <- is.finite(x);
				x[is.infinite(x)] <-
					(max(x[isfin]) +
						mean(abs(x[isfin][-1] -
						x[isfin][-length(x[isfin])])));
				x[is.nan(x)] <- 0.001; #added by tgh to handle vectors length 2
		x})

	for (i in 1:length(perf@x.values)) {
		ind.bool <- (is.finite(perf@x.values[[i]]) & is.finite(perf@y.values[[i]]))
		if (length(perf@alpha.values) > 0)
			perf@alpha.values[[i]] <- perf@alpha.values[[i]][ind.bool]
		perf@x.values[[i]] <- perf@x.values[[i]][ind.bool]
		perf@y.values[[i]] <- perf@y.values[[i]][ind.bool]
	}
	perf.sampled <- perf

	# create a list of cutoffs to interpolate off of
	alpha.values <- rev(seq(min(unlist(perf@alpha.values)),
							max(unlist(perf@alpha.values)),
							length=max(sapply(perf@alpha.values, length))))
	# interpolate by cutoff, values for y and x
	for (i in 1:length(perf.sampled@y.values)) {
		perf.sampled@x.values[[i]] <-
		  approxfun(perf@alpha.values[[i]],perf@x.values[[i]],
					rule=2, ties=mean)(alpha.values)
		perf.sampled@y.values[[i]] <-
		  approxfun(perf@alpha.values[[i]], perf@y.values[[i]],
					rule=2, ties=mean)(alpha.values)
	}

	## compute average curve
	perf.avg <- perf.sampled
	perf.avg@x.values <- list(rowMeans( data.frame( perf.avg@x.values)))
	perf.avg@y.values <- list(rowMeans( data.frame( perf.avg@y.values)))
	perf.avg@alpha.values <- list( alpha.values )

	for(i in 1:length(group$vals)){
	  ### get threshold
	  # max sensitivity plus specificity (maxSSS per Liu et al 2016)
	  # create the prediction object for ROCR. Get pres col from y, prediction from votes (=named "1")
# 	  pred <- prediction(trRes[[i]]$votes[,"1"],trRes[[i]]$y)
# 	  sens <- performance(pred,"sens")
# 	  spec <- performance(pred,"spec")
# 	  sss <- data.frame(cutSens = unlist(sens@x.values),sens = unlist(sens@y.values),
# 	                            cutSpec = unlist(spec@x.values), spec = unlist(spec@y.values))
# 	  sss$sss <- with(sss, sens + spec)
# 	  maxSSS <- min(sss[which.max(sss$sss),"cutSens"], 0.9999)
#     cutval.rf <- c(1-maxSSS, maxSSS)
# 	  names(cutval.rf) <- c("0","1")
	  
	  # get MTP: minimum training presence (minimum votes recieved [probability]
	  # for any training point)
	  allVotesPrespts <- trRes[[i]]$votes[,"1"][trRes[[i]]$y == 1]
	  MTP <- min(min(allVotesPrespts), 0.9999)
	  cutval.rf <- c(1-MTP, MTP)
	  names(cutval.rf) <- c("0","1")
	  
		#apply the cutoff to the validation data
		v.rf.pred.cut <- predict(trRes[[i]], evSet[[i]],type="response", cutoff=cutval.rf)
		#make the confusion matrix
		v.y[[i]] <- table(observed = evSet[[i]][,"pres"],
			predicted = v.rf.pred.cut)
		#add estimated accuracy measures
		v.y[[i]] <- cbind(v.y[[i]],
			"accuracy" = c(v.y[[i]][1,1]/sum(v.y[[i]][1,]), v.y[[i]][2,2]/sum(v.y[[i]][2,])))
		#add row, col names
		rownames(v.y[[i]])[rownames(v.y[[i]]) == "0"] <- "background/abs"
		rownames(v.y[[i]])[rownames(v.y[[i]]) == "1"] <- "known pres"
		colnames(v.y[[i]])[colnames(v.y[[i]]) == "0"] <- "pred. abs"
		colnames(v.y[[i]])[colnames(v.y[[i]]) == "1"] <- "pred. pres"
		print(v.y[[i]])
		#Generate kappa statistics for the confusion matrices
		v.kappa[[i]] <- Kappa(v.y[[i]][1:2,1:2])
		#True Skill Statistic
		v.tss[[i]] <- v.y[[i]][2,3] + v.y[[i]][1,3] - 1
		#Overall Accuracy
		v.OvAc[[i]] <- (v.y[[i]][[1,1]]+v.y[[i]][[2,2]])/sum(v.y[[i]][,1:2])
		### importance measures ###
		#count the number of variables
		n.var <- nrow(trRes[[i]]$importance)
		#get the importance measures (don't get GINI coeff - see Strobl et al. 2006)
		imp <- importance(trRes[[i]], class = NULL, scale = TRUE, type = NULL)
		imp <- imp[,"MeanDecreaseAccuracy"]
		#get number of variables used in each forest
		used <- varUsed(trRes[[i]])
		names(used) <- names(imp)
		t.importance[[i]] <- data.frame("meanDecreaseAcc" = imp,
									"timesUsed" = used )
	} #close loop

	#housecleaning
	rm(trSet, evSet)

	#average relevant validation/summary stats
	# Kappa - wieghted, then unweighted
	K.w <- unlist(v.kappa, recursive=TRUE)[grep("Weighted.value",
						names(unlist(v.kappa, recursive=TRUE)))]
	Kappa.w.summ <- data.frame("mean"=mean(K.w), "sd"=sd(K.w),"sem"= sd(K.w)/sqrt(length(K.w)))
	K.unw <- unlist(v.kappa, recursive=TRUE)[grep("Unweighted.value",
						names(unlist(v.kappa, recursive=TRUE)))]
	Kappa.unw.summ <- data.frame("mean"=mean(K.unw), "sd"=sd(K.unw),"sem"= sd(K.unw)/sqrt(length(K.unw)))
	#AUC - area under the curve
	auc <- unlist(v.rocr.auc)
	auc.summ <- data.frame("mean"=mean(auc), "sd"=sd(auc),"sem"= sd(auc)/sqrt(length(auc)))
	#TSS - True skill statistic
	tss <- unlist(v.tss) 
	tss.summ <- data.frame("mean"=mean(tss), "sd"=sd(tss),"sem"= sd(tss)/sqrt(length(tss)))
	#Overall Accuracy
	OvAc <- unlist(v.OvAc)
	OvAc.summ <- data.frame("mean"=mean(OvAc), "sd"=sd(OvAc),"sem"= sd(OvAc)/sqrt(length(OvAc)))
	#Specificity and Sensitivity
	v.y.flat <- abind(v.y,along=1)  #collapsed confusion matrices
	v.y.flat.sp <- v.y.flat[rownames(v.y.flat)=="background/abs",]
	v.y.flat.sp <- as.data.frame(v.y.flat.sp, row.names = 1:length(v.y.flat.sp[,1]))
	specif <- v.y.flat.sp[,"pred. abs"]/(v.y.flat.sp[,"pred. abs"] + v.y.flat.sp[,"pred. pres"])   #specificity
	specif.summ <- data.frame("mean"=mean(specif), "sd"=sd(specif),"sem"= sd(specif)/sqrt(length(specif)))
	v.y.flat.sn <- v.y.flat[rownames(v.y.flat)=="known pres",]
	v.y.flat.sn <- as.data.frame(v.y.flat.sn, row.names = 1:length(v.y.flat.sn[,1]))
	sensit <- v.y.flat.sn[,"pred. pres"]/(v.y.flat.sn[,"pred. pres"] + v.y.flat.sn[,"pred. abs"])    #sensitivity
	sensit.summ <- data.frame("mean"=mean(sensit), "sd"=sd(sensit),"sem"= sd(sensit)/sqrt(length(sensit)))

	summ.table <- data.frame(Name=c("Weighted Kappa", "Unweighted Kappa", "AUC",
									"TSS", "Overall Accuracy", "Specificity",
									"Sensitivity"),
							 Mean=c(Kappa.w.summ$mean, Kappa.unw.summ$mean,auc.summ$mean,
									tss.summ$mean, OvAc.summ$mean, specif.summ$mean,
									sensit.summ$mean),
							 SD=c(Kappa.w.summ$sd, Kappa.unw.summ$sd,auc.summ$sd,
									tss.summ$sd, OvAc.summ$sd, specif.summ$sd,
									sensit.summ$sd),
							 SEM=c(Kappa.w.summ$sem, Kappa.unw.summ$sem,auc.summ$sem,
									tss.summ$sem, OvAc.summ$sem, specif.summ$sem,
									sensit.summ$sem))
	summ.table
} else {
	cat("Only one polygon, can't do validation", "\n")
	cutval <- NA
}

# increase the number of trees for the full model
ntrees <- 2000

####
#   run the full model ----
####

rf.full <- randomForest(df.full[,indVarCols],
                        y=df.full[,depVarCol],
                        importance=TRUE,
                        ntree=ntrees,
                        mtry=mtry,
                        strata = df.full[,cv.by],
                        sampsize = sampSizeVec, replace = TRUE,
                        norm.votes = TRUE)
####
# Importance measures ----
####
#get the importance measures (don't get GINI coeff - see Strobl et al. 2006)
f.imp <- importance(rf.full, class = NULL, scale = TRUE, type = NULL)
f.imp <- f.imp[,"MeanDecreaseAccuracy"]

db <- dbConnect(SQLite(),dbname=nm_db_file)  
# get importance data, set up a data frame
EnvVars <- data.frame(gridName = names(f.imp), impVal = f.imp, fullName="", stringsAsFactors = FALSE)
#set the query for the following lookup, note it builds many queries, equal to the number of vars
SQLquery <- paste("SELECT gridName, fullName FROM lkpEnvVars WHERE gridName COLLATE NOCASE in ('", paste(EnvVars$gridName,sep=", "),
					"'); ", sep="")
#cycle through all select statements, put the results in the df
for(i in 1:length(EnvVars$gridName)) {
  try(EnvVars$fullName[i] <- as.character(dbGetQuery(db, statement = SQLquery[i])[,2]))
}
##clean up
dbDisconnect(db)

###
# partial plot data ----
###

#get the order for the importance charts
ord <- order(EnvVars$impVal, decreasing = TRUE)
pPlotListLen <- min(c(length(ord), 9))

# sample 1/0 equal to prevalance in df.full
pplotSampN <- min(c(length(df.full[,1])/10, 10000)) # take 10% of samples, or 10000, whichever is less
sampprop <- length(df.full$pres[df.full$pres==1])/length(df.full$pres)
pplotSamp <- c(sample((1:length(df.full$pres))[df.full$pres==1], size = ceiling(pplotSampN*sampprop), replace = F),
               sample((1:length(df.full$pres))[df.full$pres==0], size = ceiling(pplotSampN*(1-sampprop)), replace = F))
df.full.pplot <- df.full[pplotSamp,indVarCols]

# cluster pPlots
message("Working on ", pPlotListLen, " partial plots...")
ls.pp <- as.list(names(f.imp[ord][1:pPlotListLen]))
cl <- makeCluster(min(parallel::detectCores() - 1, pPlotListLen), type = "SOCK") 
clusterExport(cl, list("rf.full","df.full.pplot","ls.pp","EnvVars"), envir = environment()) 
clusterEvalQ(cl, library(randomForest)) 
pPlots <- snow::parLapply(cl, x = ls.pp, fun = function(x) {
  pp <- do.call("partialPlot", list(x = rf.full, pred.data = df.full.pplot,
                                    x.var = x,
                                    which.class = 1,
                                    plot = FALSE))
  pp$gridName <- x
  pp$fname <- EnvVars$fullName[EnvVars$gridName==x]
  return(pp)
})
names(pPlots) <- 1:length(pPlots)
stopCluster(cl)
rm(ls.pp, df.full.pplot, sampprop, pplotSamp, pplotSampN)

# save the project, return to the original working directory
dir.create(paste0(loc_model, "/", model_species,"/outputs/rdata"), recursive = T, showWarnings = F)
setwd(paste0(loc_model, "/", model_species,"/outputs"))

# don't save fn args/vars
for(i in 1:length(modelrun_meta_data)) assign(names(modelrun_meta_data)[i], modelrun_meta_data[[i]])
ls.save <- ls(all.names = TRUE)[!ls(all.names = TRUE) %in% c("begin_step","rdata","prompt","scrpt",
                                                             "run_steps","prompt","fn_args", names(fn_args))]
save(list = ls.save, file = paste0("rdata/", model_run_name,".Rdata"), envir = environment())

# write model metadata to db
# tblModelResults
db <- dbConnect(SQLite(),dbname=nm_db_file)  
# add/remove vars internal comment update
if (!is.null(fn_args$add_vars)) {
  add.comm <- paste0(" Non-standard variables (", paste(fn_args$add_vars, collapse = ", "), ") were included in this model.")
  model_comments <- paste0(model_comments, add.comm)
}
if (!is.null(fn_args$remove_vars)) {
  add.comm <- paste0(" The standard variables (", paste(fn_args$remove_vars, collapse = ", "), ") were excluded from this model.")
  model_comments <- paste0(model_comments, add.comm)
}
tblModelResults <- data.frame(model_run_name = model_run_name, EGT_ID = ElementNames$EGT_ID, table_code = baseName,
                              internal_comments = model_comments, metadata_comments = metaData_comments,
                              model_comp_name = model_comp_name, modeller = modeller,
                              model_start_time = model_start_time, model_end_time = as.character(Sys.time()),
                              r_version = r_version, repo_head = repo_head, seed = seed)
dbWriteTable(db, "tblModelResults", tblModelResults, append = T)

# tblModelResultsVarsUsed
varImpDB <- data.frame(model_run_name = model_run_name, gridName = tolower(envvar_list), inFinalModel = 0)
varImpDB <- merge(varImpDB, EnvVars[c("gridName","impVal")], by = "gridName", all.x = T)
varImpDB$inFinalModel[!is.na(varImpDB$impVal)] <- 1
dbWriteTable(db, "tblModelResultsVarsUsed", varImpDB, append = T)
dbDisconnect(db)

message(paste0("Saved rdata file: '", model_run_name , "'."))
