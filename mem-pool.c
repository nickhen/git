/*
 * Memory Pool implementation logic.
 */

#include "cache.h"
#include "mem-pool.h"

#define BLOCK_GROWTH_SIZE 1024*1024 - sizeof(struct mp_block);

static struct mp_block *mem_pool_alloc_block(struct mem_pool *mem_pool, size_t block_alloc)
{
	struct mp_block *p;

	mem_pool->pool_alloc += sizeof(struct mp_block) + block_alloc;
	p = xmalloc(st_add(sizeof(struct mp_block), block_alloc));

	p->next_block = mem_pool->mp_block;
	p->next_free = (char *)p->space;
	p->end = p->next_free + block_alloc;

	mem_pool->mp_block = p;

	if (!mem_pool->mp_block_tail)
		mem_pool->mp_block_tail = p;

	return p;
}

static void *mem_pool_alloc_custom(struct mem_pool *mem_pool, size_t block_alloc)
{
	struct mp_block *p;

	mem_pool->pool_alloc += sizeof(struct mp_block) + block_alloc;
	p = xmalloc(st_add(sizeof(struct mp_block), block_alloc));

	p->next_block = NULL;
	p->next_free = (char *)p->space;
	p->end = p->next_free + block_alloc;

	if (mem_pool->mp_block_tail)
		mem_pool->mp_block_tail->next_block = p;
	else
		mem_pool->mp_block = p;

	mem_pool->mp_block_tail = p;
	return p;
}

void mem_pool_init(struct mem_pool **mem_pool, size_t initial_size)
{
	struct mem_pool *pool;

	if (*mem_pool)
		return;

	pool = xcalloc(1, sizeof(*pool));

	pool->block_alloc = BLOCK_GROWTH_SIZE;

	if (initial_size > 0)
		mem_pool_alloc_block(pool, initial_size);

	*mem_pool = pool;
}

void mem_pool_discard(struct mem_pool *mem_pool, int invalidate_memory)
{
	struct mp_block *block, *block_to_free;

	for (block = mem_pool->mp_block; block;)
	{
		block_to_free = block;
		block = block->next_block;

		if (invalidate_memory)
			memset(block_to_free->space, 0xDD, ((char *)block_to_free->end) - ((char *)block_to_free->space));

		free(block_to_free);
	}

	free(mem_pool);
}

void *mem_pool_alloc(struct mem_pool *mem_pool, size_t len)
{
	struct mp_block *p = NULL;
	void *r;

	/* round up to a 'uintmax_t' alignment */
	if (len & (sizeof(uintmax_t) - 1))
		len += sizeof(uintmax_t) - (len & (sizeof(uintmax_t) - 1));

	if (mem_pool->mp_block &&
	    mem_pool->mp_block->end - mem_pool->mp_block->next_free >= len)
		p = mem_pool->mp_block;

	if (!p) {
		if (len >= (mem_pool->block_alloc / 2))
			return mem_pool_alloc_custom(mem_pool, len);

		p = mem_pool_alloc_block(mem_pool, mem_pool->block_alloc);
	}

	r = p->next_free;
	p->next_free += len;
	return r;
}

void *mem_pool_calloc(struct mem_pool *mem_pool, size_t count, size_t size)
{
	size_t len = st_mult(count, size);
	void *r = mem_pool_alloc(mem_pool, len);
	memset(r, 0, len);
	return r;
}

int mem_pool_contains(struct mem_pool *mem_pool, void *mem)
{
	struct mp_block *p;

	/* Check if memory is allocated in a block */
	for (p = mem_pool->mp_block; p; p = p->next_block)
		if ((mem >= ((void *)p->space)) &&
		    (mem < ((void *)p->end)))
			return 1;

	return 0;
}

void mem_pool_combine(struct mem_pool *dst, struct mem_pool *src)
{
	/* Append the blocks from src to dst */
	if (dst->mp_block && src->mp_block) {
		/*
		 * src and dst have blocks, append
		 * blocks from src to dst.
		 */
		dst->mp_block_tail->next_block = src->mp_block;
		dst->mp_block_tail = src->mp_block_tail;
	} else if (src->mp_block) {
		/*
		 * src has blocks, dst is empty
		 * use pointers from src to set up dst.
		 */
		dst->mp_block = src->mp_block;
		dst->mp_block_tail = src->mp_block_tail;
	} else {
		// src is empty, nothing to do.
	}

	dst->pool_alloc += src->pool_alloc;
	src->pool_alloc = 0;
	src->mp_block = NULL;
	src->mp_block_tail = NULL;
}
