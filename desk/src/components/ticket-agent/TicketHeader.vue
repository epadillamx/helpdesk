<template>
  <LayoutHeader>
    <template #left-header>
      <div class="flex flex-col truncate">
        <Breadcrumbs :items="breadcrumbs" class="breadcrumbs -ml-0.5">
          <template #prefix="{ item }">
            <Icon
              v-if="item.icon"
              :icon="item.icon"
              class="mr-1 h-4 flex items-center justify-center self-center"
            />
          </template>
        </Breadcrumbs>
        <TicketSLA />
      </div>
    </template>
    <template #right-header>
      <div class="flex gap-2 items-center">
        <MultipleAvatar
          :avatars="JSON.stringify(viewers)"
          size="md"
          :hide-name="true"
        />
        <!-- Navigation -->
        <TicketNavigation :key="ticket?.name" />
        <!-- Custom Actions -->
        <div v-if="normalActions.length" class="flex gap-2">
          <Button v-for="action in normalActions" v-bind="action">
            <template v-if="action.icon" #prefix>
              <FeatherIcon :name="action.icon" class="h-4 w-4" />
            </template>
          </Button>
        </div>
        <div v-if="groupedWithLabelActions.length">
          <div v-for="g in groupedWithLabelActions" :key="g.label">
            <Dropdown v-slot="{ open }" :options="g.action">
              <Button :label="g.label">
                <template #suffix>
                  <FeatherIcon
                    :name="open ? 'chevron-up' : 'chevron-down'"
                    class="h-4"
                  />
                </template>
              </Button>
            </Dropdown>
          </div>
        </div>
        <!-- Status -->
        <Dropdown :options="statusDropdown" placement="right">
          <template #default="{ open }">
            <Button :label="ticket.doc.status" ref="statusRef">
              <template #prefix>
                <IndicatorIcon
                  :class="
                    ticketStatusStore.getStatus(ticket.doc.status)?.parsed_color
                  "
                />
              </template>
            </Button>
          </template>
        </Dropdown>
        <!-- Core Actions + Custom Actions -->
        <Dropdown
          v-if="groupedActions[0]?.items?.length >= 1"
          :options="groupedActions"
          placement="right"
        >
          <Button icon="more-horizontal" />
        </Dropdown>
      </div>
    </template>
  </LayoutHeader>
  <TicketMergeModal
    :ticket="ticket.doc"
    v-if="showMergeModal"
    v-model="showMergeModal"
    @update="ticket.reload()"
  />
  <TicketSubjectModal v-model="showSubjectDialog" />

  <!-- Modal: pide horas trabajadas al pasar a Resolved/Closed -->
  <Dialog
    v-model="showResolutionDialog"
    :options="{
      title: __('Horas trabajadas'),
      actions: [
        {
          label: __('Cancelar'),
          onClick: cancelResolution,
        },
        {
          label: __('Confirmar'),
          variant: 'solid',
          onClick: confirmResolution,
        },
      ],
    }"
  >
    <template #body-content>
      <p class="mb-3 text-sm text-gray-700">
        {{
          __(
            'Para marcar este ticket como "{0}" ingresá las horas trabajadas (decimal, ej: 1.5).'
          ).replace('{0}', pendingStatus || "")
        }}
      </p>
      <FormControl
        v-model.number="resolutionHours"
        type="number"
        :placeholder="'1.5'"
        :label="__('Horas trabajadas')"
        :step="0.25"
        :min="0"
        autofocus
        @keyup.enter="confirmResolution"
      />
    </template>
  </Dialog>
</template>

<script setup lang="ts">
import { MultipleAvatar } from "@/components";
import LayoutHeader from "@/components/LayoutHeader.vue";
import TicketMergeModal from "@/components/ticket/TicketMergeModal.vue";
import { setupCustomizations } from "@/composables/formCustomisation";
import { useNotifyTicketUpdate } from "@/composables/realtime";
import { useShortcut } from "@/composables/shortcuts";
import { useView } from "@/composables/useView";
import { useAuthStore } from "@/stores/auth";
import { globalStore } from "@/stores/globalStore";
import { useTicketStatusStore } from "@/stores/ticketStatus";
import { __ } from "@/translation";
import {
  ActivitiesSymbol,
  CustomizationSymbol,
  TicketSymbol,
  View,
} from "@/types";
import { HDTicketStatus } from "@/types/doctypes";
import { getIcon } from "@/utils";
import {
  Breadcrumbs,
  Button,
  call,
  createResource,
  Dialog,
  Dropdown,
  FormControl,
  toast,
} from "frappe-ui";
import {
  computed,
  ComputedRef,
  h,
  inject,
  onMounted,
  PropType,
  ref,
  useTemplateRef,
  watchEffect,
} from "vue";
import { useRoute, useRouter } from "vue-router";
import LucideMerge from "~icons/lucide/merge";
import { IndicatorIcon } from "../icons";
import TicketNavigation from "./TicketNavigation.vue";
import TicketSLA from "./TicketSLA.vue";
import TicketSubjectModal from "./TicketSubjectModal.vue";
const { isAdmin } = useAuthStore();
const { $dialog } = globalStore();

defineProps({
  viewers: {
    type: Array as PropType<string[]>,
    required: true,
  },
});

const route = useRoute();
const router = useRouter();
const { findView } = useView("HD Ticket");
const ticketStatusStore = useTicketStatusStore();

const ticket = inject(TicketSymbol)!;
const customizations = inject(CustomizationSymbol)!;
const activities = inject(ActivitiesSymbol)!;
const showSubjectDialog = ref(false);

const { notifyTicketUpdate } = useNotifyTicketUpdate(ticket.value?.name);

// Status que requieren capturar horas trabajadas antes de aplicar.
// Si agregás otro status que tambien deba pedirlo, sumalo aca y al
// validador server-side en hd_ticket.py:validate_resolution_hours().
const STATUSES_REQUIRING_HOURS = ["Resolved", "Closed"];
const showResolutionDialog = ref(false);
const resolutionHours = ref<number | null>(null);
const pendingStatus = ref<string | null>(null);

function applyStatus(newStatus: string, extra: Record<string, any> = {}) {
  notifyTicketUpdate("Status", newStatus);
  // Si el status no cambia y no hay extras, no hace falta llamar al server.
  if (
    ticket.value.doc.status === newStatus &&
    Object.keys(extra).length === 0
  ) {
    return;
  }
  ticket.value.setValue.submit(
    { status: newStatus, ...extra },
    {
      onSuccess() {
        activities.value.reload();
      },
    }
  );
}

function handleStatusChange(newStatus: string) {
  if (STATUSES_REQUIRING_HOURS.includes(newStatus)) {
    pendingStatus.value = newStatus;
    // Pre-cargar valor previo si existe (por si re-resuelven el ticket).
    resolutionHours.value =
      (ticket.value.doc as any).resolution_hours || null;
    showResolutionDialog.value = true;
  } else {
    applyStatus(newStatus);
  }
}

function confirmResolution() {
  if (!resolutionHours.value || resolutionHours.value <= 0) {
    toast.error(
      __("Las horas trabajadas son obligatorias y deben ser mayores a 0.")
    );
    return;
  }
  applyStatus(pendingStatus.value!, {
    resolution_hours: resolutionHours.value,
  });
  showResolutionDialog.value = false;
  pendingStatus.value = null;
  resolutionHours.value = null;
}

function cancelResolution() {
  showResolutionDialog.value = false;
  pendingStatus.value = null;
  resolutionHours.value = null;
}

const statusDropdown = computed(() => {
  const statuses =
    ticketStatusStore.statuses.data?.filter((s) => s.enabled) || [];
  return statuses.map((o: HDTicketStatus) => ({
    label: o.label_agent,
    value: o.label_agent,
    onClick: () => handleStatusChange(o.label_agent),
    icon: () =>
      h(IndicatorIcon, {
        class: o.parsed_color,
      }),
  }));
});
const breadcrumbs = computed(() => {
  let items = [{ label: __("Tickets"), route: { name: "TicketsAgent" } }];
  if (route.query.view) {
    const currView: ComputedRef<View> = findView(route.query.view as string);
    if (currView) {
      items.push({
        label: currView.value?.label,
        icon: getIcon(currView.value?.icon),
        route: { name: "TicketsAgent", query: { view: currView.value?.name } },
      });
    }
  }
  items.push({
    label: ticket.value.doc?.subject,
    onClick: () => {
      showSubjectDialog.value = true;
    },
  });
  return items;
});

function updateField(fieldname: string, value: string, callback = () => {}) {
  const doc = ticket.value;
  doc.setValue.submit({
    [fieldname]: value,
  });
  callback();
}

function handleDeleteTicket() {
  $dialog({
    title: __(`Delete ticket #${ticket?.value?.name}`),
    message: __(
      "Are you sure you want to delete this ticket? This is an irreversible action and cannot be undone."
    ),
    actions: [
      {
        label: __("Delete"),
        theme: "red",
        iconLeft: "trash-2",
        variant: "solid",
        onClick({ close }) {
          call("frappe.client.delete", {
            doctype: "HD Ticket",
            name: ticket?.value?.doc.name,
          })
            .then(() => {
              toast.success(__("Ticket deleted successfully."));
              router.push({ name: "TicketsAgent" });
            })
            .catch((err: any) => {
              toast.error(err || __("Failed to delete ticket."));
            });
          close();
        },
      },
    ],
  });
}

const ticketCount = createResource({
  url: "frappe.client.get_count",
  makeParams: () => ({
    doctype: "HD Ticket",
    filters: {
      status_category: ["!=", "Resolved"],
      is_merged: 0,
    },
  }),
  auto: true,
});
const showMergeModal = ref(false);
const showMergeOption = computed(() => {
  return (
    !ticket?.value?.doc?.is_merged &&
    ["Open", "Paused"].includes(ticket?.value?.doc?.status_category) &&
    ticketCount.data > 1
  );
});
const defaultActions = computed(() => {
  let items = [];

  if (showMergeOption.value) {
    items.push({
      label: __("Merge Ticket"),
      icon: LucideMerge,
      condition: () => !ticket.value.doc.is_merged,
      onClick: () => (showMergeModal.value = true),
    });
  }

  return [
    {
      group: __("Default actions"),
      hideLabel: true,
      items,
    },
  ];
});

const deleteAction = computed(() => {
  if (!isAdmin) return [];
  return [
    {
      group: __("Default actions"),
      hideLabel: true,
      items: [
        {
          label: __("Delete"),
          component: h(Button, {
            label: __("Delete"),
            variant: "ghost",
            iconLeft: "trash-2",
            theme: "red",
            style: "width: 100%; justify-content: flex-start;",
            onClick: handleDeleteTicket,
          }),
        },
      ],
    },
  ];
});

const actions = ref<any[]>([]);
const normalActions = computed(() => {
  return actions.value.filter((action) => !action.group);
});

const groupedWithLabelActions = computed(() => {
  let _actions = [];

  actions.value
    .filter((action) => action.buttonLabel && action.group)
    .forEach((action) => {
      let groupIndex = _actions.findIndex(
        (a) => a.label === action.buttonLabel
      );
      if (groupIndex > -1) {
        _actions[groupIndex].action.push(action);
      } else {
        _actions.push({
          label: action.buttonLabel,
          action: [action],
        });
      }
    });
  return _actions;
});

const groupedActions = computed(() => {
  let _actions = [];
  _actions = _actions.concat(defaultActions.value);
  _actions = _actions.concat(
    actions.value.filter((action) => action.group && !action.buttonLabel)
  );
  _actions = _actions.concat(deleteAction.value);
  return _actions;
});

const customizationCtx = computed(() => ({
  doc: ticket?.value?.doc,
  call,
  router,
  toast,
  $dialog: globalStore().$dialog,
  updateField,
  createToast: toast.create,
}));

// to manage the correct  customization context for actions, happens because of navigation between tickets using buttons
watchEffect(async () => {
  if (customizations.value?.data) {
    await setupCustomizations(
      customizations.value.data,
      customizationCtx.value
    );

    actions.value = [...(customizations.value?.data?._customActions || [])];
  }
});

const statusRef = useTemplateRef("statusRef");

onMounted(() => {
  useShortcut("s", () => {
    statusRef.value?.$el?.nextElementSibling?.click();
  });
});
</script>

<style>
.breadcrumbs button {
  background-color: inherit !important;
  &:hover,
  &:focus {
    background-color: inherit !important;
  }
}
</style>
