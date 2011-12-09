#' Active learning with "Query by Bagging"
#'
#' The 'query by bagging' approach to active learning applies bootstrap
#' aggregating (bagging) by randomly sampling with replacement B times from the
#' training data to create a committe of B classifiers. Our goal is to "query
#' the oracle" with the observations that have the maximum disagreement among the
#' B trained classifiers.
#'
#' Note that this approach is similar to "Query by Committee" (QBC), but each
#' committee member uses the same classifier trained on a resampled subset of
#' the labeled training data. With the QBC approach, the user specifies a
#' comittee with C supervised classifiers that are each trained on the labeled
#' training data. Also, note that we we have implemented QBC as query_by_committee.
#'
#' To determine maximum disagreement among bagged committe members, we have
#' implemented three approaches:
#' 1. vote_entropy: query the unlabeled observation that maximizes the vote
#' entropy among all commitee members
#' 2. post_entropy: query the unlabeled observation that maximizes the entropy
#' of average posterior probabilities of all committee members
#' 3. kullback: query the unlabeled observation that maximizes the
#' Kullback-Leibler divergence between the
#' label distributions of any one committe member and the consensus.
#' The 'disagreement' argument must be one of the three: 'kullback' is the default.
#'
#' To calculate the committee disagreement, we use the formulae from Dr. Burr Settles'
#' "Active Learning Literature Survey" available on his website. At the time this function
#' was coded, the literature survey had last been updated on January 26, 2010.
#'
#' We require a user-specified supervised classifier and its corresponding
#' prediction (classification) function. These must be specified as functions in
#' 'train' and 'predict', respectively. We assume that the 'train' function
#' accepts two arguments, x and y, as the matrix of feature vectors and their
#' corresponding labels, respectively. The 'predict' function is assumed to
#' accept a trained object as its first argument and a matrix of test
#' observations as its second argument. Furthermore, we assume that 'predict'
#' returns a list that contains a 'posterior' component that is a matrix of the
#' posterior probabilities of class membership; the (i,j)th entry of the matrix
#' must be the posterior probability of the ith observation belong to class j.
#' If the 'posterior' component is not available when required, an error is thrown.
#'
#' Usually, it is straightforward to implement a wrapper function so that 'train'
#' and 'predict' can be used.
#'
#' Additional arguments to 'train' can be passed via '...'.
#' 
#' Unlabeled observations in 'y' are assumed to have NA for a label.
#'
#' It is often convenient to query unlabeled observations in batch. By default,
#' we query the unlabeled observations with the largest uncertainty measure
#' value. With the 'num_query' the user can specify the number of observations
#' to return in batch. If there are ties in the uncertainty measure values, they
#' are broken by the order in which the unlabeled observations are given.
#'
#' We use the 'parallel' package to perform the bagging in parallel.
#'
#' @param x a matrix containing the labeled and unlabeled data
#' @param y a vector of the labels for each observation in x.
#' Use NA for unlabeled.
#' @param disagreement a string that contains the disagreement measure among the
#' committee members. See above for details.
#' @param train a function to train a classifier
#' @param predict a function to predict (classify) observations
#' @param num_query the number of observations to be be queried.
#' @param C the number of bootstrap committee members
#' @param ... additional arguments that are passed to train
#' @return a list that contains the least_certain observation and miscellaneous
#' results. See above for details.
#' @export
query_by_bagging <- function(x, y, disagreement = "kullback", train, predict, num_query = 1, C = 50, num_cores = 1, ...) {
	unlabeled <- which(is.na(y))
	n <- length(y) - length(unlabeled)

  train_x <- x[-unlabeled, ]
  train_y <- y[-unlabeled]
  test_x <- x[unlabeled, ]

	# Bagged predictions
	bagged_pred <- mclapply(seq_len(C), function(b) {
		boot <- sample(n, replace = T)
		train_out <- train(x = train_x[boot, ], y = train_y[boot], ...)
		predict(train_out, test_x)
	}, mc.cores = num_cores)
	
	bagged_post <- lapply(bagged_pred, function(x) x$posterior)
	bagged_class <- do.call(rbind, lapply(bagged_pred, function(x) x$class))
	
	obs_disagreement <- switch(uncertainty,
                             vote_entropy = apply(bagged_class, 2, function(x) {
                               entropy.empirical(table(factor(x, levels = classes)))
                             }),
                             post_entropy = {
                               if (is_null(bagged_post)) {
                                 stop("The specified 'predict' function must return a list with a 'posterior' component.")
                               }
                               bagged_post <- lapply(bagged_pred, function(x) x$posterior)
                               average_posteriors <- Reduce('+', bagged_post) / length(bagged_post)
                               apply(average_posteriors, 1, function(obs_post) {
                                 entropy.plugin(obs_post)
                               })
                             },
                             kullback = {
                               if (is_null(bagged_post)) {
                                 stop("The specified 'predict' function must return a list with a 'posterior' component.")
                               }
                               bagged_post <- lapply(bagged_pred, function(x) x$posterior)
                               consensus_prob <- Reduce('+', bagged_post) / length(bagged_post)
                               kl_post_by_member <- lapply(bagged_post, function(x) rowSums(x * log(x / consensus_prob)))
                               Reduce('+', kl_post_by_member) / length(kl_post_by_member)
                             }
                             )
	
	query <- order(obs_disagreement, decreasing = T)[seq_len(num_query)]
	
	list(query = query, obs_disagreement = obs_disagreement, bagged_class = bagged_class, bagged_post = bagged_post, unlabeled = unlabeled)
}
