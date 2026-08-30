import { router, useLocalSearchParams } from "expo-router";
import React, { useEffect, useMemo, useState } from "react";
import { KeyboardAvoidingView, Platform, Pressable, ScrollView, StyleSheet, Switch, Text, TextInput, View } from "react-native";
import { SafeAreaView } from "react-native-safe-area-context";
import { useRemote } from "@/remote/remote-provider";
import { useTheme, palette } from "@/ui/theme";
import { fieldsForAction, serializeArguments, type ArgumentField, type ArgumentValue } from "@/remote/utility-form";
import { roleCanWrite } from "@/remote/security";
import { ActionButton, Card, EmptyState, InlineNotice, ScreenHeader, SectionLabel, Tag } from "@/ui/primitives";

export default function UtilityDetailScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const remote = useRemote();
  const theme = useTheme();
  const action = remote.utilities.find((value) => value.id === id);
  const utilityState = action ? remote.utilityStates[action.module] : undefined;
  const refreshUtilityState = remote.refreshUtilityState;
  const macOnline = remote.macOnline;
  const fields = useMemo(() => action ? fieldsForAction(action, utilityState) : [], [action, utilityState]);
  const [values, setValues] = useState<Record<string, ArgumentValue>>({});
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const canWrite = roleCanWrite(remote.activeEnvironment?.role);

  useEffect(() => {
    if (!action || !macOnline) return;
    void refreshUtilityState(action.module).catch(() => undefined);
  }, [action, macOnline, refreshUtilityState]);

  if (!action) {
    return <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]}><EmptyState title="Utility unavailable" message="This action is no longer advertised by the connected Mac." /></SafeAreaView>;
  }

  const prepare = async () => {
    setBusy(true);
    setError(undefined);
    try {
      const command = await remote.prepareCommand(`utility.${action.id}`, serializeArguments(fields, values));
      if (command.risk === "read_only") {
        await remote.applyCommand(command);
        router.replace({ pathname: "/command/[id]", params: { id: command.commandID, actionID: command.actionID } });
      } else {
        router.push({ pathname: "/confirm", params: { command: JSON.stringify(command) } });
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The utility could not be prepared.");
    } finally {
      setBusy(false);
    }
  };

  const riskTone = action.risk === "destructive" ? "danger" : action.risk === "sensitive" ? "warning" : action.risk === "read_only" ? "neutral" : "accent";
  const buttonTitle = busy ? "Preparing…" : !canWrite ? "Viewer access is read-only" : !action.allowed ? "Enable this utility on the Mac" : action.risk === "read_only" ? "Run utility" : "Review and run";

  return (
    <SafeAreaView style={[styles.safe, { backgroundColor: theme.background }]} edges={["bottom"]}>
      <KeyboardAvoidingView style={styles.safe} behavior={Platform.OS === "ios" ? "padding" : undefined} keyboardVerticalOffset={96}>
        <ScrollView contentInsetAdjustmentBehavior="automatic" keyboardShouldPersistTaps="handled" contentContainerStyle={styles.content}>
          <ScreenHeader eyebrow={action.module} title={action.title} detail={action.summary} />
          <View style={styles.tags}>
            <Tag tone={riskTone}>{action.risk.replace("_", " ")}</Tag>
            {action.producesArtifact ? <Tag tone="accent">Returns to Library</Tag> : null}
          </View>
          {action.requiredPermissions.length ? <InlineNotice title="Mac permission required" message={`MacScope needs ${action.requiredPermissions.join(" and ")}. macOS may ask you to grant it the first time.`} tone="warning" /> : null}
          {action.producesArtifact ? <InlineNotice title="Result delivered to your phone" message="When the Mac finishes, the capture appears in Library where you can preview, play, save, or share it." /> : null}

          {fields.length ? <SectionLabel detail="Answer these questions before MacScope prepares the command.">Command settings</SectionLabel> : <SectionLabel detail="This utility has no additional settings.">Ready to run</SectionLabel>}
          {fields.map((field, index) => <FieldControl key={field.name} index={index + 1} field={field} value={values[field.name] ?? field.initialValue} onChange={(value) => setValues((current) => ({ ...current, [field.name]: value }))} />)}

          {error ? <InlineNotice title="Could not prepare this command" message={error} tone="danger" /> : null}
          <ActionButton title={buttonTitle} disabled={busy || !canWrite || !action.allowed || !remote.macOnline} onPress={() => void prepare()} destructive={action.risk === "destructive"} />
          {!remote.macOnline ? <Text style={[styles.helper, { color: palette.amber }]}>Open MacScope on the paired Mac before running this utility.</Text> : null}
        </ScrollView>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

function FieldControl({ field, value, index, onChange }: { field: ArgumentField; value: ArgumentValue; index: number; onChange(value: ArgumentValue): void }) {
  const theme = useTheme();
  if (field.kind === "boolean") {
    if (field.optional) {
      return (
        <Card>
          <FieldHeading field={field} index={index} />
          <View accessibilityRole="radiogroup" style={styles.booleanChoices}>
            <BooleanChoice label="Use current" selected={value === ""} onPress={() => onChange("")} />
            <BooleanChoice label="No" selected={value === false || value === "false"} onPress={() => onChange(false)} />
            <BooleanChoice label="Yes" selected={value === true || value === "true"} onPress={() => onChange(true)} />
          </View>
        </Card>
      );
    }
    return <Card><View style={styles.booleanRow}><View style={styles.fieldCopy}><Text style={[styles.step, { color: theme.accent }]}>QUESTION {index}</Text><Text selectable style={[styles.question, { color: theme.text }]}>{field.question}</Text><Text selectable style={[styles.description, { color: theme.secondary }]}>{field.description}</Text></View><Switch value={value === true} onValueChange={onChange} trackColor={{ false: theme.subtle, true: theme.accent }} thumbColor={theme.elevated} /></View></Card>;
  }
  if (field.kind === "choice") {
    return (
      <Card>
        <FieldHeading field={field} index={index} />
        <View style={styles.choiceList}>{field.options.map((option) => {
          const selected = value === option.value;
          return <Pressable key={option.value} accessibilityRole="radio" accessibilityState={{ selected }} onPress={() => onChange(option.value)} style={[styles.choice, { borderColor: selected ? theme.accent : theme.border, backgroundColor: selected ? `${theme.accent}14` : theme.subtle }]}><View style={[styles.radio, { borderColor: selected ? theme.accent : theme.secondary }]}>{selected ? <View style={[styles.radioDot, { backgroundColor: theme.accent }]} /> : null}</View><View style={styles.fieldCopy}><Text style={[styles.choiceTitle, { color: theme.text }]}>{option.label}</Text>{option.detail ? <Text style={[styles.description, { color: theme.secondary }]}>{option.detail}</Text> : null}</View></Pressable>;
        })}</View>
      </Card>
    );
  }
  const text = String(value);
  const multiline = field.kind === "multiline" || field.kind === "array";
  if (field.kind === "number" && field.nullable) {
    const settingValue = text === "" ? "keep" : text === "null" ? "off" : "value";
    const setValue = () => onChange(String(field.min != null && field.min > 0 ? field.min : 1));
    return (
      <Card>
        <FieldHeading field={field} index={index} />
        <View accessibilityRole="radiogroup" style={styles.nullableChoices}>
          <BooleanChoice label="Keep current" selected={settingValue === "keep"} onPress={() => onChange("")} />
          <BooleanChoice label={field.description.toLowerCase().includes("cancel") ? "Cancel" : "Turn off"} selected={settingValue === "off"} onPress={() => onChange("null")} />
          <BooleanChoice label="Set value" selected={settingValue === "value"} onPress={setValue} />
        </View>
        {settingValue === "value" ? <NumberInput field={field} text={text} onChange={onChange} /> : null}
      </Card>
    );
  }
  return (
    <Card>
      <FieldHeading field={field} index={index} />
      <View style={styles.inputRow}>
        {field.kind === "number" && field.step ? <StepButton label="−" onPress={() => onChange(stepNumber(text, -(field.step ?? 1), field))} /> : null}
        <TextInput value={text} onChangeText={onChange} placeholder={field.kind === "array" ? "One Mac path per line" : field.optional ? "Optional" : `Enter ${field.label.toLowerCase()}`} placeholderTextColor={theme.secondary} keyboardType={field.kind === "number" ? "numbers-and-punctuation" : "default"} autoCapitalize="none" autoCorrect={false} multiline={multiline} textAlignVertical={multiline ? "top" : "center"} style={[styles.input, multiline && styles.multiline, { color: theme.text, backgroundColor: theme.subtle, borderColor: theme.border }]} />
        {field.kind === "number" && field.step ? <StepButton label="+" onPress={() => onChange(stepNumber(text, field.step ?? 1, field))} /> : null}
      </View>
      {field.kind === "number" && (field.min != null || field.max != null || field.exclusiveMin) ? <Text style={[styles.range, { color: theme.secondary }]}>{rangeLabel(field)}</Text> : null}
    </Card>
  );
}

function NumberInput({ field, text, onChange }: { field: ArgumentField; text: string; onChange(value: ArgumentValue): void }) {
  const theme = useTheme();
  return <><View style={styles.inputRow}>{field.step ? <StepButton label="−" onPress={() => onChange(stepNumber(text, -(field.step ?? 1), field))} /> : null}<TextInput value={text} onChangeText={onChange} placeholder={`Enter ${field.label.toLowerCase()}`} placeholderTextColor={theme.secondary} keyboardType="numbers-and-punctuation" autoCapitalize="none" autoCorrect={false} style={[styles.input, { color: theme.text, backgroundColor: theme.subtle, borderColor: theme.border }]} />{field.step ? <StepButton label="+" onPress={() => onChange(stepNumber(text, field.step ?? 1, field))} /> : null}</View>{field.min != null || field.max != null || field.exclusiveMin ? <Text style={[styles.range, { color: theme.secondary }]}>{rangeLabel(field)}</Text> : null}</>;
}

function BooleanChoice({ label, selected, onPress }: { label: string; selected: boolean; onPress(): void }) {
  const theme = useTheme();
  return <Pressable accessibilityRole="radio" accessibilityState={{ selected }} onPress={onPress} style={[styles.booleanChoice, { borderColor: selected ? theme.accent : theme.border, backgroundColor: selected ? `${theme.accent}14` : theme.subtle }]}><Text style={[styles.booleanChoiceText, { color: selected ? theme.accent : theme.text }]}>{label}</Text></Pressable>;
}

function FieldHeading({ field, index }: { field: ArgumentField; index: number }) {
  const theme = useTheme();
  return <View style={styles.heading}><Text style={[styles.step, { color: theme.accent }]}>QUESTION {index}</Text><Text selectable style={[styles.question, { color: theme.text }]}>{field.question}</Text><Text selectable style={[styles.description, { color: theme.secondary }]}>{field.description}</Text></View>;
}

function StepButton({ label, onPress }: { label: string; onPress(): void }) {
  const theme = useTheme();
  return <Pressable accessibilityRole="button" accessibilityLabel={label === "+" ? "Increase" : "Decrease"} onPress={onPress} style={[styles.stepButton, { backgroundColor: theme.subtle, borderColor: theme.border }]}><Text style={[styles.stepButtonText, { color: theme.text }]}>{label}</Text></Pressable>;
}

function stepNumber(value: string, delta: number, field: ArgumentField): string {
  const current = Number(value) || 0;
  const minimum = field.exclusiveMin ? field.step ?? 1 : field.min ?? -Infinity;
  return String(Math.max(minimum, Math.min(field.max ?? Infinity, current + delta)));
}

function rangeLabel(field: ArgumentField): string {
  if (field.exclusiveMin) return field.max == null ? "Allowed: greater than 0" : `Allowed: greater than 0 to ${field.max}`;
  if (field.min != null && field.max == null) return `Allowed: ${field.min} or more`;
  if (field.min == null && field.max != null) return `Allowed: up to ${field.max}`;
  return `Allowed: ${field.min} to ${field.max}`;
}

const styles = StyleSheet.create({
  safe: { flex: 1 }, content: { paddingHorizontal: 18, paddingTop: 12, paddingBottom: 42, gap: 17 }, tags: { flexDirection: "row", flexWrap: "wrap", gap: 7 },
  booleanRow: { flexDirection: "row", alignItems: "center", gap: 14 }, fieldCopy: { flex: 1, gap: 4 }, heading: { gap: 4 }, step: { fontSize: 10, fontWeight: "900", letterSpacing: 1.1 }, question: { fontSize: 17, lineHeight: 22, fontWeight: "700", letterSpacing: -0.3 }, description: { fontSize: 12, lineHeight: 17 },
  booleanChoices: { flexDirection: "row", gap: 8 }, booleanChoice: { flex: 1, minHeight: 44, alignItems: "center", justifyContent: "center", borderWidth: 1, borderRadius: 12 }, booleanChoiceText: { fontSize: 13, fontWeight: "800" },
  nullableChoices: { flexDirection: "row", gap: 8, flexWrap: "wrap" },
  choiceList: { gap: 8 }, choice: { minHeight: 54, flexDirection: "row", alignItems: "center", gap: 11, borderRadius: 13, borderWidth: 1, paddingHorizontal: 13, paddingVertical: 10 }, choiceTitle: { fontSize: 14, fontWeight: "700" }, radio: { width: 20, height: 20, borderRadius: 10, borderWidth: 1.5, alignItems: "center", justifyContent: "center" }, radioDot: { width: 10, height: 10, borderRadius: 5 },
  inputRow: { flexDirection: "row", alignItems: "stretch", gap: 8 }, input: { flex: 1, minHeight: 50, borderWidth: 1, borderRadius: 13, borderCurve: "continuous", paddingHorizontal: 13, fontSize: 15 }, multiline: { minHeight: 112, paddingTop: 13 }, stepButton: { width: 48, minHeight: 50, borderWidth: 1, borderRadius: 13, alignItems: "center", justifyContent: "center" }, stepButtonText: { fontSize: 22, fontWeight: "500" }, range: { fontSize: 11 }, helper: { textAlign: "center", fontSize: 12, lineHeight: 17 },
});
