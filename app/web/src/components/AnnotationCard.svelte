<script>
  import { deleteAnnotation } from '../lib/app.svelte.js';
  import { describe } from '../lib/ax.js';
  import { fileName } from '../lib/sdk.js';
  import { icon } from '../lib/icons.js';

  let { annotation: a } = $props();
  let deleting = $state(false);

  // A box the SDK matched to a tagged view has no accessibility target; name the view instead.
  // Several picked together (Shift) go by their names.
  const tag = $derived(a.source?.[0]);
  const target = $derived(a.parts?.length > 1 ? a.label : a.target ? describe(a.target) : tag ? `${tag.name} · ${fileName(tag.file)}:${tag.line}` : (a.label ?? 'Area'));

  async function remove() {
    deleting = true;
    if (!(await deleteAnnotation(a.id))) deleting = false;
  }
</script>

<li class="item">
  <img class="item-thumb" src="/images/{a.id}-crop.jpg" alt="">
  <div class="item-body">
    <p class="item-comment">{a.comment}</p>
    <div class="item-meta"><span class="badge {a.status}">{a.status}</span><span class="item-target">{target} · {a.id}</span></div>
    {#each a.replies as reply, i (i)}
      <div class="item-reply"><b>{reply.from}</b> <span>{reply.message}</span></div>
    {/each}
    {#if a.resolution}
      <div class="item-reply"><b>{a.status === 'dismissed' ? 'dismissed' : 'done'}</b> <span>{a.resolution}</span></div>
    {/if}
  </div>
  <button class="item-delete icon-btn" title="Delete annotation" aria-label="Delete annotation {a.id}" disabled={deleting} onclick={remove}>
    {@html icon('trash')}
  </button>
</li>
