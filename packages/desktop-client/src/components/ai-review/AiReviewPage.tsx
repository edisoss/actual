// Fork: review page for categories suggested by the external AI categorizer.
import { useMemo, useState } from 'react';
import type { ReactNode } from 'react';
import { Trans, useTranslation } from 'react-i18next';

import { Button } from '@actual-app/components/button';
import { Menu } from '@actual-app/components/menu';
import { Select } from '@actual-app/components/select';
import type { SelectOption } from '@actual-app/components/select';
import { SpaceBetween } from '@actual-app/components/space-between';
import { Text } from '@actual-app/components/text';
import { theme } from '@actual-app/components/theme';
import { View } from '@actual-app/components/view';
import * as monthUtils from '@actual-app/core/shared/months';

import { Page } from '#components/Page';
import { useAccounts } from '#hooks/useAccounts';
import { useCategories } from '#hooks/useCategories';
import { useDateFormat } from '#hooks/useDateFormat';
import { useFormat } from '#hooks/useFormat';
import { useLocale } from '#hooks/useLocale';
import { usePayeesById } from '#hooks/usePayees';
import { useQuery } from '#hooks/useQuery';

import {
  acceptAiSuggestions,
  aiReviewQuery,
  hasAiReviewTag,
  removeAiReviewTag,
} from './aiReview';
import type { AiReviewTransaction } from './aiReview';

export function AiReviewPage() {
  const { t } = useTranslation();
  const format = useFormat();
  const locale = useLocale();
  const dateFormat = useDateFormat() || 'MM/dd/yyyy';
  const { data: accounts = [] } = useAccounts();
  const { data: payeesById = {} } = usePayeesById();
  const { data: categoryData } = useCategories();
  const { data, isLoading } = useQuery<AiReviewTransaction>(
    () => aiReviewQuery(),
    [],
  );

  const [overrides, setOverrides] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);

  const transactions = useMemo(
    () => (data ?? []).filter(tx => hasAiReviewTag(tx.notes)),
    [data],
  );

  const accountNames = useMemo(
    () => Object.fromEntries(accounts.map(a => [a.id, a.name])),
    [accounts],
  );

  const categoryOptions = useMemo(() => {
    const options: SelectOption[] = [];
    for (const group of categoryData?.grouped ?? []) {
      if (group.hidden) continue;
      const categories = (group.categories ?? []).filter(c => !c.hidden);
      if (categories.length === 0) continue;
      options.push([Menu.label, group.name]);
      for (const category of categories) {
        options.push([category.id, category.name]);
      }
    }
    return options;
  }, [categoryData]);

  async function accept(list: ReadonlyArray<AiReviewTransaction>) {
    setBusy(true);
    try {
      await acceptAiSuggestions(list, overrides);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Page header={t('Review AI categories')}>
      <SpaceBetween
        style={{ justifyContent: 'space-between', marginBottom: 15 }}
      >
        <Text style={{ color: theme.pageTextLight }}>
          {transactions.length > 0 ? (
            <Trans count={transactions.length}>
              The AI sorted {{ count: transactions.length }} transactions.
              Accept them, or pick another category first.
            </Trans>
          ) : isLoading ? (
            t('Loading…')
          ) : (
            t(
              'Nothing to review. New transactions are sorted by the AI automatically.',
            )
          )}
        </Text>
        {transactions.length > 0 && (
          <Button
            variant="primary"
            isDisabled={busy}
            onPress={() => accept(transactions)}
          >
            <Trans>Accept all</Trans>
          </Button>
        )}
      </SpaceBetween>

      {transactions.length > 0 && (
        <View
          style={{
            border: `1px solid ${theme.tableBorder}`,
            borderRadius: 6,
            backgroundColor: theme.tableBackground,
            overflow: 'auto',
          }}
        >
          <Row header>
            <Cell width={110}>
              <Trans>Date</Trans>
            </Cell>
            <Cell flex>
              <Trans>Payee</Trans>
            </Cell>
            <Cell width={160}>
              <Trans>Account</Trans>
            </Cell>
            <Cell width={120} align="right">
              <Trans>Amount</Trans>
            </Cell>
            <Cell width={260}>
              <Trans>AI category</Trans>
            </Cell>
            <Cell width={100} />
          </Row>
          {transactions.map(tx => {
            const payeeName =
              (tx.payee && payeesById[tx.payee]?.name) ||
              tx.imported_payee ||
              t('(no payee)');
            const notes = removeAiReviewTag(tx.notes);
            const selected = overrides[tx.id] ?? tx.category ?? '';
            return (
              <Row key={tx.id}>
                <Cell width={110}>
                  {monthUtils.format(tx.date, dateFormat, locale)}
                </Cell>
                <Cell flex>
                  <Text style={{ fontWeight: 500 }}>{payeeName}</Text>
                  {notes && (
                    <Text
                      style={{ color: theme.pageTextSubdued, fontSize: 12 }}
                    >
                      {notes}
                    </Text>
                  )}
                </Cell>
                <Cell width={160}>{accountNames[tx.account] ?? ''}</Cell>
                <Cell width={120} align="right">
                  <Text
                    style={{
                      color:
                        tx.amount < 0 ? theme.errorText : theme.noticeTextLight,
                    }}
                  >
                    {format(tx.amount, 'financial')}
                  </Text>
                </Cell>
                <Cell width={260}>
                  <Select
                    options={categoryOptions}
                    value={selected}
                    defaultLabel={t('Choose category')}
                    onChange={id =>
                      setOverrides(prev => ({ ...prev, [tx.id]: id }))
                    }
                    style={{ width: '100%' }}
                  />
                </Cell>
                <Cell width={100} align="right">
                  <Button
                    variant={
                      overrides[tx.id] && overrides[tx.id] !== tx.category
                        ? 'primary'
                        : 'normal'
                    }
                    isDisabled={busy || !selected}
                    onPress={() => accept([tx])}
                  >
                    <Trans>Accept</Trans>
                  </Button>
                </Cell>
              </Row>
            );
          })}
        </View>
      )}
    </Page>
  );
}

function Row({ header, children }: { header?: boolean; children: ReactNode }) {
  return (
    <View
      style={{
        flexDirection: 'row',
        alignItems: 'center',
        gap: 10,
        padding: '8px 12px',
        minWidth: 860,
        borderBottom: `1px solid ${theme.tableBorder}`,
        ...(header && {
          backgroundColor: theme.tableHeaderBackground,
          color: theme.tableHeaderText,
          fontWeight: 600,
        }),
      }}
    >
      {children}
    </View>
  );
}

function Cell({
  width,
  flex,
  align,
  children,
}: {
  width?: number;
  flex?: boolean;
  align?: 'right';
  children?: ReactNode;
}) {
  return (
    <View
      style={{
        ...(flex ? { flex: 1, minWidth: 0 } : { width, flexShrink: 0 }),
        alignItems: align === 'right' ? 'flex-end' : 'flex-start',
      }}
    >
      {children}
    </View>
  );
}
