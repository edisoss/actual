// Fork: review categories suggested by the external AI categorizer.
//
// The categorizer sets a category on uncategorized transactions and adds the
// AI_REVIEW_TAG to their notes. Accepting a suggestion removes the tag; the
// categorizer learns from which category the transaction ends up with.
import { send } from '@actual-app/core/platform/client/connection';
import { q } from '@actual-app/core/shared/query';
import type { TransactionEntity } from '@actual-app/core/types/models';

export const AI_REVIEW_TAG = '#ai-review';

export type AiReviewTransaction = Pick<
  TransactionEntity,
  | 'id'
  | 'date'
  | 'amount'
  | 'account'
  | 'payee'
  | 'imported_payee'
  | 'notes'
  | 'category'
>;

export function aiReviewQuery() {
  return q('transactions')
    .filter({ notes: { $like: `%${AI_REVIEW_TAG}%` } })
    .select([
      'id',
      'date',
      'amount',
      'account',
      'payee',
      'imported_payee',
      'notes',
      'category',
    ])
    .orderBy({ date: 'desc' });
}

const TAG_PATTERN = new RegExp(`(^|\\s)${AI_REVIEW_TAG}(?=\\s|$)`, 'g');

export function hasAiReviewTag(notes: string | null | undefined) {
  return !!notes && new RegExp(TAG_PATTERN.source).test(notes);
}

export function removeAiReviewTag(notes: string | null | undefined): string {
  return (notes ?? '')
    .replace(TAG_PATTERN, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim();
}

export async function acceptAiSuggestions(
  transactions: ReadonlyArray<AiReviewTransaction>,
  categoryOverrides: Readonly<Record<string, string>> = {},
) {
  if (transactions.length === 0) {
    return;
  }
  await send('transactions-batch-update', {
    updated: transactions.map(t => ({
      id: t.id,
      category: categoryOverrides[t.id] ?? t.category,
      notes: removeAiReviewTag(t.notes),
    })),
  });
}
