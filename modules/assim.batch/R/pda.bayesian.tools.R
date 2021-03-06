##' Paramater Data Assimilation using BayesianTools R Package
##'
##'
##' @title Paramater Data Assimilation using BayesianTools
##' @param settings = a pecan settings list
##'
##' @return nothing. Diagnostic plots, MCMC samples, and posterior distributions
##'  are saved as files and db records.
##'
##' @author Mike Dietze
##' @author Istem Fer, Ryan Kelly
##' @export
pda.bayesian.tools <- function(settings, params.id = NULL, param.names = NULL, prior.id = NULL,
                               chain = NULL, iter = NULL, adapt = NULL, adj.min = NULL, 
                               ar.target = NULL, jvar = NULL, n.knot = NULL) {
  
  library(BayesianTools)
  
  sampler <- settings$assim.batch$bt.settings$sampler
  
  ## this bit of code is useful for defining the variables 
  ## passed to this function if you are debugging
  if (FALSE) {
    params.id <- param.names <- prior.id <- chain <- iter <- NULL
    n.knot <- adapt <- adj.min <- ar.target <- jvar <- NULL
  }
  
  ## -------------------------------------- Setup ------------------------------------- 
  ## Handle settings
  settings <- pda.settings(
    settings = settings, params.id = params.id, param.names = param.names, 
    prior.id = prior.id, chain = chain, iter = iter, adapt = adapt,
    adj.min = adj.min, ar.target = ar.target, jvar = jvar, n.knot = n.knot)
  
  ## will be used to check if multiplicative Gaussian is requested
  any.mgauss <- sapply(settings$assim.batch$inputs, `[[`, "likelihood")
  
  ## Open database connection
  if (settings$database$bety$write) {
    con <- try(db.open(settings$database$bety), silent = TRUE)
    if (is(con, "try-error")) {
      con <- NULL
    } else {
      on.exit(db.close(con))
    }
  } else {
    con <- NULL
  }
  
  bety <- src_postgres(dbname = settings$database$bety$dbname, 
                       host = settings$database$bety$host, 
                       user = settings$database$bety$user, 
                       password = settings$database$bety$password)
  
  ## Load priors
  temp        <- pda.load.priors(settings, bety$con)
  prior.list  <- temp$prior
  settings    <- temp$settings
  pname       <- lapply(prior.list, rownames)
  n.param.all <- sapply(prior.list, nrow)
  
  ## Load data to assimilate against
  inputs  <- load.pda.data(settings, bety)
  n.input <- length(inputs)
  
  ## Set model-specific functions
  do.call("require", list(paste0("PEcAn.", settings$model$type)))
  my.write.config <- paste("write.config.", settings$model$type, sep = "")
  if (!exists(my.write.config)) {
    logger.severe(paste(my.write.config, "does not exist. Please make sure that the PEcAn interface is loaded for", 
                        settings$model$type))
  }
  
  ## Select parameters to constrain
  prior.ind <- lapply(seq_along(settings$pfts), 
                      function(x) which(pname[[x]] %in% settings$assim.batch$param.names[[x]]))
  n.param   <- sapply(prior.ind, length)
  
  ## NOTE: The listed samplers here require more than 1 parameter for now because of the way their
  ## cov is calculated
  if (sampler %in% c("M", "AM", "DR", "DRAM", "DREAM", "DREAMzs", "SMC") & sum(n.param) < 2) {
    logger.error(paste0(sampler, " sampler can be used with >=2 paramaters"))
  }
  
  ## Get the workflow id
  if ("workflow" %in% names(settings)) {
    workflow.id <- settings$workflow$id
  } else {
    workflow.id <- -1
  }
  
  ## Create an ensemble id
  settings$assim.batch$ensemble.id <- pda.create.ensemble(settings, con, workflow.id)
  
  ## Set up likelihood functions
  llik.fn <- pda.define.llik.fn(settings)
  
  prior.all     <- do.call("rbind", prior.list)
  ## Set prior distribution functions (d___, q___, r___, and multivariate versions)
  prior.fn.all  <- pda.define.prior.fn(prior.all)
  prior.ind.all <- which(unlist(pname) %in% unlist(settings$assim.batch$param.names))
  pname.all     <- unlist(pname)
  
  
  ## Set initial conditions
  parm          <- sapply(prior.fn.all$qprior, eval, list(p = 0.5))
  names(parm)   <- pname.all
  
  
  ## Create prior class object for BayesianTools
  bt.prior      <- pda.create.btprior(prior.all[prior.ind.all, ])
  
  ## Create log-likelihood function for createbayesianSetup{BayesianTools}
  
  bt.likelihood <- function(x) {
    parm[prior.ind.all] <- x
    
    # Convert parm to a list of 1-row data frame
    if (is.null(dim(parm))) {
      pnames <- names(parm)
      run.params <- as.data.frame(matrix(parm, nrow = 1))
      names(run.params) <- pnames
    }
    run.params <- list(run.params)
    
    now <- format(Sys.time(), "%Y%m%d%H%M%OS3")
    
    run.id <- pda.init.run(settings, con, my.write.config, workflow.id, run.params, n = 1, run.names = paste("run", 
                                                                                                             now, sep = "."))
    
    ## Start model run
    start.model.runs(settings, settings$database$bety$write)
    
    ## Read model outputs
    model.out <- pda.get.model.output(settings, run.id, bety, inputs)
    
    # retrieve n
    n.of.obs <- sapply(inputs,`[[`, "n") 
    names(n.of.obs) <- sapply(model.out,names)
    
    # handle bias parameters if multiplicative Gaussian is listed in the likelihoods
    if(any(unlist(any.mgauss) == "multipGauss")) {
      isbias <- which(unlist(any.mgauss) == "multipGauss")
      # testing now
      nbias <- 1
      bias.list <- return.bias(isbias, list(model.out), inputs, prior.list, nbias)
      bias.terms <- bias.list$bias.params
    } else {
      bias.terms <- NULL
    }
    
    if(!is.null(bias.terms)){
      all.bias <- lapply(bias.terms, function(n) n[1,])
      all.bias <- do.call("rbind", all.bias)
    } else {
      all.bias <- NULL
    }
    
    ## calculate error statistics      
    pda.errors <- pda.calc.error(settings, con, model_out = model.out, run.id, inputs, all.bias)
    llik.par <- pda.calc.llik.par(settings, n = n.of.obs, 
                                  error.stats = unlist(pda.errors))
    ## Calculate likelihood
    LL.new <- pda.calc.llik(pda.errors = unlist(pda.errors), llik.fn, llik.par)
    
    return(LL.new)
  }
  
  ## Create bayesianSetup object for BayesianTools
  bayesianSetup <- createBayesianSetup(bt.likelihood, bt.prior, best = parm[prior.ind.all], parallel = FALSE)
  
  logger.info(paste0("Extracting upper and lower boundaries from priors."))  # M/AM/DR/DRAM can't work with -Inf, Inf values
  rng <- matrix(c(sapply(prior.fn.all$qprior[prior.ind.all], eval, list(p = 1e-05)), 
                  sapply(prior.fn.all$qprior[prior.ind.all], eval, list(p = 0.99999))), 
                nrow = sum(n.param))
  # if it's a uniform distribution, use given boundaries
  for (i in 1:sum(n.param)) {
    if (prior.all[prior.ind.all, ][i, 1] == "unif") {
      rng[i, 1] <- prior.all[prior.ind.all, ][i, 2]
      rng[i, 2] <- prior.all[prior.ind.all, ][i, 3]
    }
  }
  
  bayesianSetup$prior$lower <- rng[, 1]
  bayesianSetup$prior$upper <- rng[, 2]
  
  ## Apply BayesianTools specific settings
  bt.settings <- pda.settings.bt(settings)
  
  if (!is.null(settings$assim.batch$extension)) {
    load(settings$assim.batch$out.path)  # loads previous out list
    out <- runMCMC(bayesianSetup = out, sampler = sampler, settings = bt.settings)
  } else {
    ## central function in BayesianTools
    out <- runMCMC(bayesianSetup = bayesianSetup, sampler = sampler, settings = bt.settings)
  }
  
  # save the out object for restart functionality and further inspection
  settings$assim.batch$out.path <- file.path(settings$outdir, 
                                             paste0("out.pda", 
                                                    settings$assim.batch$ensemble.id, 
                                                    ".Rdata"))
  save(out, file = settings$assim.batch$out.path)
  
  # prepare for post-process
  samples <- getSample(out, parametersOnly = TRUE)  # getSample{BayesianTools}
  colnames(samples) <- pname.all[prior.ind.all]
  mcmc.list <- list(samples)
  
  # Separate each PFT's parameter samples to their own list
  mcmc.param.list <- list()
  ind <- 0
  for (i in seq_along(settings$pfts)) {
    mcmc.param.list[[i]] <- lapply(mcmc.list, function(x) x[, (ind + 1):(ind + n.param[i]), drop = FALSE])
    ind <- ind + n.param[i]
  }
  
  ## ------------------------------------ Clean up ------------------------------------ 
  ## Save outputs to plots, files, and db
  settings <- pda.postprocess(settings, con, mcmc.param.list, pname, prior.list, prior.ind)
  
  ## close database connection
  if (!is.null(con)) {
    db.close(con)
  }
  
  ## Output an updated settings list
  return(settings)
  
} # pda.bayesian.tools
