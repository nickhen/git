#!/bin/sh

test_description='commit graph'
. ./test-lib.sh

test_expect_success 'setup full repo' '
	mkdir full &&
	cd "$TRASH_DIRECTORY/full" &&
	git init &&
	git config core.commitGraph true &&
	objdir=".git/objects"
'

test_expect_success 'verify graph with no graph file' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph verify
'

test_expect_success 'write graph with no packs' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph write --object-dir . &&
	test_path_is_file info/commit-graph
'

test_expect_success 'create commits and repack' '
	cd "$TRASH_DIRECTORY/full" &&
	for i in $(test_seq 3)
	do
		test_commit $i &&
		git branch commits/$i
	done &&
	git repack
'

graph_git_two_modes() {
	git -c core.graph=true $1 >output
	git -c core.graph=false $1 >expect
	test_cmp output expect
}

graph_git_behavior() {
	MSG=$1
	DIR=$2
	BRANCH=$3
	COMPARE=$4
	test_expect_success "check normal git operations: $MSG" '
		cd "$TRASH_DIRECTORY/$DIR" &&
		graph_git_two_modes "log --oneline $BRANCH" &&
		graph_git_two_modes "log --topo-order $BRANCH" &&
		graph_git_two_modes "log --graph $COMPARE..$BRANCH" &&
		graph_git_two_modes "branch -vv" &&
		graph_git_two_modes "merge-base -a $BRANCH $COMPARE"
	'
}

graph_git_behavior 'no graph' full commits/3 commits/1

graph_read_expect() {
	OPTIONAL=""
	NUM_CHUNKS=3
	if test ! -z $2
	then
		OPTIONAL=" $2"
		NUM_CHUNKS=$((3 + $(echo "$2" | wc -w)))
	fi
	cat >expect <<- EOF
	header: 43475048 1 1 $NUM_CHUNKS 0
	num_commits: $1
	chunks: oid_fanout oid_lookup commit_metadata$OPTIONAL
	EOF
	git commit-graph read >output &&
	test_cmp expect output
}

test_expect_success 'write graph' '
	cd "$TRASH_DIRECTORY/full" &&
	graph1=$(git commit-graph write) &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "3"
'

graph_git_behavior 'graph exists' full commits/3 commits/1

test_expect_success 'Add more commits' '
	cd "$TRASH_DIRECTORY/full" &&
	git reset --hard commits/1 &&
	for i in $(test_seq 4 5)
	do
		test_commit $i &&
		git branch commits/$i
	done &&
	git reset --hard commits/2 &&
	for i in $(test_seq 6 7)
	do
		test_commit $i &&
		git branch commits/$i
	done &&
	git reset --hard commits/2 &&
	git merge commits/4 &&
	git branch merge/1 &&
	git reset --hard commits/4 &&
	git merge commits/6 &&
	git branch merge/2 &&
	git reset --hard commits/3 &&
	git merge commits/5 commits/7 &&
	git branch merge/3 &&
	git repack
'

# Current graph structure:
#
#   __M3___
#  /   |   \
# 3 M1 5 M2 7
# |/  \|/  \|
# 2    4    6
# |___/____/
# 1

test_expect_success 'write graph with merges' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph write &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "10" "large_edges"
'

graph_git_behavior 'merge 1 vs 2' full merge/1 merge/2
graph_git_behavior 'merge 1 vs 3' full merge/1 merge/3
graph_git_behavior 'merge 2 vs 3' full merge/2 merge/3

test_expect_success 'Add one more commit' '
	cd "$TRASH_DIRECTORY/full" &&
	test_commit 8 &&
	git branch commits/8 &&
	ls $objdir/pack | grep idx >existing-idx &&
	git repack &&
	ls $objdir/pack| grep idx | grep -v --file=existing-idx >new-idx
'

# Current graph structure:
#
#      8
#      |
#   __M3___
#  /   |   \
# 3 M1 5 M2 7
# |/  \|/  \|
# 2    4    6
# |___/____/
# 1

graph_git_behavior 'mixed mode, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'mixed mode, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'write graph with new commit' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph write &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "11" "large_edges"
'

graph_git_behavior 'full graph, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'full graph, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'write graph with nothing new' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph write &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "11" "large_edges"
'

graph_git_behavior 'cleared graph, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'cleared graph, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'build graph from latest pack with closure' '
	cd "$TRASH_DIRECTORY/full" &&
	cat new-idx | git commit-graph write --stdin-packs &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "9" "large_edges"
'

graph_git_behavior 'graph from pack, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'graph from pack, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'build graph from commits with closure' '
	cd "$TRASH_DIRECTORY/full" &&
	git tag -a -m "merge" tag/merge merge/2 &&
	git rev-parse tag/merge >commits-in &&
	git rev-parse merge/1 >>commits-in &&
	cat commits-in | git commit-graph write --stdin-commits &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "6"
'

graph_git_behavior 'graph from commits, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'graph from commits, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'build graph from commits with append' '
	cd "$TRASH_DIRECTORY/full" &&
	git rev-parse merge/3 | git commit-graph write --stdin-commits --append &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "10" "large_edges"
'

graph_git_behavior 'append graph, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'append graph, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'build graph using --reachable' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit-graph write --reachable &&
	test_path_is_file $objdir/info/commit-graph &&
	graph_read_expect "11" "large_edges"
'

graph_git_behavior 'append graph, commit 8 vs merge 1' full commits/8 merge/1
graph_git_behavior 'append graph, commit 8 vs merge 2' full commits/8 merge/2

test_expect_success 'setup bare repo' '
	cd "$TRASH_DIRECTORY" &&
	git clone --bare --no-local full bare &&
	cd bare &&
	git config core.commitGraph true &&
	baredir="./objects"
'

graph_git_behavior 'bare repo, commit 8 vs merge 1' bare commits/8 merge/1
graph_git_behavior 'bare repo, commit 8 vs merge 2' bare commits/8 merge/2

test_expect_success 'write graph in bare repo' '
	cd "$TRASH_DIRECTORY/bare" &&
	git commit-graph write &&
	test_path_is_file $baredir/info/commit-graph &&
	graph_read_expect "11" "large_edges"
'

graph_git_behavior 'bare repo with graph, commit 8 vs merge 1' bare commits/8 merge/1
graph_git_behavior 'bare repo with graph, commit 8 vs merge 2' bare commits/8 merge/2

test_expect_success 'perform fast-forward merge in full repo' '
	cd "$TRASH_DIRECTORY/full" &&
	git checkout -b merge-5-to-8 commits/5 &&
	git merge commits/8 &&
	git show-ref -s merge-5-to-8 >output &&
	git show-ref -s commits/8 >expect &&
	test_cmp expect output
'

test_expect_success 'check that gc clears commit-graph' '
	cd "$TRASH_DIRECTORY/full" &&
	git commit --allow-empty -m "blank" &&
	git commit-graph write --reachable &&
	cp $objdir/info/commit-graph commit-graph-before-gc &&
	git reset --hard HEAD~1 &&
	git config gc.commitGraph true &&
	git gc &&
	cp $objdir/info/commit-graph commit-graph-after-gc &&
	! test_cmp commit-graph-before-gc commit-graph-after-gc &&
	git commit-graph write --reachable &&
	test_cmp commit-graph-after-gc $objdir/info/commit-graph
'

# the verify tests below expect the commit-graph to contain
# exactly the commits reachable from the commits/8 branch.
# If the file changes the set of commits in the list, then the
# offsets into the binary file will result in different edits
# and the tests will likely break.

test_expect_success 'git commit-graph verify' '
	cd "$TRASH_DIRECTORY/full" &&
	git rev-parse commits/8 | git commit-graph write --stdin-commits &&
	git commit-graph verify >output
'

NUM_COMMITS=9
NUM_OCTOPUS_EDGES=2
HASH_LEN=20
GRAPH_BYTE_VERSION=4
GRAPH_BYTE_HASH=5
GRAPH_BYTE_CHUNK_COUNT=6
GRAPH_CHUNK_LOOKUP_OFFSET=8
GRAPH_CHUNK_LOOKUP_WIDTH=12
GRAPH_CHUNK_LOOKUP_ROWS=5
GRAPH_BYTE_OID_FANOUT_ID=$GRAPH_CHUNK_LOOKUP_OFFSET
GRAPH_BYTE_OID_LOOKUP_ID=`expr $GRAPH_CHUNK_LOOKUP_OFFSET + \
			      1 \* $GRAPH_CHUNK_LOOKUP_WIDTH`
GRAPH_BYTE_COMMIT_DATA_ID=`expr $GRAPH_CHUNK_LOOKUP_OFFSET + \
				2 \* $GRAPH_CHUNK_LOOKUP_WIDTH`
GRAPH_FANOUT_OFFSET=`expr $GRAPH_CHUNK_LOOKUP_OFFSET + \
			  $GRAPH_CHUNK_LOOKUP_WIDTH \* $GRAPH_CHUNK_LOOKUP_ROWS`
GRAPH_BYTE_FANOUT1=`expr $GRAPH_FANOUT_OFFSET + 4 \* 4`
GRAPH_BYTE_FANOUT2=`expr $GRAPH_FANOUT_OFFSET + 4 \* 255`
GRAPH_OID_LOOKUP_OFFSET=`expr $GRAPH_FANOUT_OFFSET + 4 \* 256`
GRAPH_BYTE_OID_LOOKUP_ORDER=`expr $GRAPH_OID_LOOKUP_OFFSET + $HASH_LEN \* 8`
GRAPH_BYTE_OID_LOOKUP_MISSING=`expr $GRAPH_OID_LOOKUP_OFFSET + $HASH_LEN \* 4 + 10`
GRAPH_COMMIT_DATA_OFFSET=`expr $GRAPH_OID_LOOKUP_OFFSET + $HASH_LEN \* $NUM_COMMITS`
GRAPH_BYTE_COMMIT_TREE=$GRAPH_COMMIT_DATA_OFFSET
GRAPH_BYTE_COMMIT_PARENT=`expr $GRAPH_COMMIT_DATA_OFFSET + $HASH_LEN`
GRAPH_BYTE_COMMIT_EXTRA_PARENT=`expr $GRAPH_COMMIT_DATA_OFFSET + $HASH_LEN + 4`
GRAPH_BYTE_COMMIT_WRONG_PARENT=`expr $GRAPH_COMMIT_DATA_OFFSET + $HASH_LEN + 3`
GRAPH_BYTE_COMMIT_GENERATION=`expr $GRAPH_COMMIT_DATA_OFFSET + $HASH_LEN + 8`
GRAPH_BYTE_COMMIT_DATE=`expr $GRAPH_COMMIT_DATA_OFFSET + $HASH_LEN + 12`
GRAPH_COMMIT_DATA_WIDTH=`expr $HASH_LEN + 16`
GRAPH_OCTOPUS_DATA_OFFSET=`expr $GRAPH_COMMIT_DATA_OFFSET + \
				$GRAPH_COMMIT_DATA_WIDTH \* $NUM_COMMITS`
GRAPH_BYTE_OCTOPUS=`expr $GRAPH_OCTOPUS_DATA_OFFSET + 4`
GRAPH_BYTE_FOOTER=`expr $GRAPH_OCTOPUS_DATA_OFFSET + 4 \* $NUM_OCTOPUS_EDGES`

# usage: corrupt_graph_and_verify <position> <data> <string>
# Manipulates the commit-graph file at the position
# by inserting the data, then runs 'git commit-graph verify'
# and places the output in the file 'err'. Test 'err' for
# the given string.
corrupt_graph_and_verify() {
	pos=$1
	data="${2:-\0}"
	grepstr=$3
	cd "$TRASH_DIRECTORY/full" &&
	test_when_finished mv commit-graph-backup $objdir/info/commit-graph &&
	cp $objdir/info/commit-graph commit-graph-backup &&
	printf "$data" | dd of="$objdir/info/commit-graph" bs=1 seek="$pos" conv=notrunc &&
	test_must_fail git commit-graph verify 2>test_err &&
	grep -v "^+" test_err >err
	grep "$grepstr" err
}

test_expect_success 'detect bad signature' '
	corrupt_graph_and_verify 0 "\0" \
		"graph signature"
'

test_expect_success 'detect bad version' '
	corrupt_graph_and_verify $GRAPH_BYTE_VERSION "\02" \
		"graph version"
'

test_expect_success 'detect bad hash version' '
	corrupt_graph_and_verify $GRAPH_BYTE_HASH "\02" \
		"hash version"
'

test_expect_success 'detect bad chunk count' '
	corrupt_graph_and_verify $GRAPH_BYTE_CHUNK_COUNT "\02" \
		"missing the Commit Data chunk"
'

test_expect_success 'detect missing OID fanout chunk' '
	corrupt_graph_and_verify $GRAPH_BYTE_OID_FANOUT_ID "\0" \
		"missing the OID Fanout chunk"
'

test_expect_success 'detect missing OID lookup chunk' '
	corrupt_graph_and_verify $GRAPH_BYTE_OID_LOOKUP_ID "\0" \
		"missing the OID Lookup chunk"
'

test_expect_success 'detect missing commit data chunk' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_DATA_ID "\0" \
		"missing the Commit Data chunk"
'

test_expect_success 'detect incorrect fanout' '
	corrupt_graph_and_verify $GRAPH_BYTE_FANOUT1 "\01" \
		"fanout value"
'

test_expect_success 'detect incorrect fanout' '
	corrupt_graph_and_verify $GRAPH_BYTE_FANOUT2 "\01" \
		"fanout value"
'

test_expect_success 'detect incorrect OID order' '
	corrupt_graph_and_verify $GRAPH_BYTE_OID_LOOKUP_ORDER "\01" \
		"incorrect OID order"
'

test_expect_success 'detect OID not in object database' '
	corrupt_graph_and_verify $GRAPH_BYTE_OID_LOOKUP_MISSING "\01" \
		"from object database"
'

test_expect_success 'detect incorrect tree OID' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_TREE "\01" \
		"root tree OID for commit"
'

test_expect_success 'detect incorrect parent int-id' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_PARENT "\01" \
		"invalid parent"
'

test_expect_success 'detect extra parent int-id' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_EXTRA_PARENT "\00" \
		"is too long"
'

test_expect_success 'detect incorrect tree OID' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_WRONG_PARENT "\01" \
		"commit-graph parent for"
'

test_expect_success 'detect incorrect generation number' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_GENERATION "\01" \
		"generation"
'

test_expect_success 'detect incorrect commit date' '
	corrupt_graph_and_verify $GRAPH_BYTE_COMMIT_DATE "\01" \
		"commit date"
'

test_expect_success 'detect incorrect parent for octopus merge' '
	corrupt_graph_and_verify $GRAPH_BYTE_OCTOPUS "\01" \
		"invalid parent"
'

test_expect_success 'detect invalid checksum hash' '
	corrupt_graph_and_verify $GRAPH_BYTE_FOOTER "\00" \
		"incorrect checksum"
'

test_expect_success 'git fsck (checks commit-graph)' '
	cd "$TRASH_DIRECTORY/full" &&
	git fsck &&
	corrupt_graph_and_verify $GRAPH_BYTE_FOOTER "\00" \
		"incorrect checksum" &&
	test_must_fail git fsck
'

test_done
